function [ stat, MFG, R_res, x_res ] = pendulum_MC(  )

addpath('../matrix Fisher');
addpath('../rotation3d');

Ns = 1000000;

% parameters
J = diag([0.0152492,0.0142639,0.00380233]);

rho = [0;0;0.0679878];
m = 1.85480;
g = 3;

% time
sf = 200;
T = 2;
Nt = T*sf+1;

% initial conditions
S = diag([10,10,10]);
U = expRot([pi*2/3,0,0]);
R = pdf_MF_sampling_gpu(U*S,Ns);

Miu = [0;0;0];
Sigma = 1^2*eye(3);
x = mvnrnd(Miu,Sigma,Ns)';
x = gpuArray(x);

% statistics
MFG.U = zeros(3,3,Nt);
MFG.V = zeros(3,3,Nt);
MFG.S = zeros(3,3,Nt);
MFG.Miu = zeros(3,Nt);
MFG.Sigma = zeros(3,3,Nt);
MFG.P = zeros(3,3,Nt);

stat.ER = zeros(3,3,Nt);
stat.Ex = zeros(3,Nt);
stat.Varx = zeros(3,3,Nt);
stat.EvR = zeros(3,Nt);
stat.ExvR = zeros(3,3,Nt);
stat.EvRvR = zeros(3,3,Nt);

[stat.ER(:,:,1),stat.Ex(:,1),stat.Varx(:,:,1),stat.EvR(:,1),stat.ExvR(:,:,1),stat.EvRvR(:,:,1),...
        MFG.U(:,:,1),MFG.S(:,:,1),MFG.V(:,:,1),MFG.P(:,:,1),MFG.Miu(:,1),MFG.Sigma(:,:,1)] = ...
        get_stat(gather(R),gather(x),zeros(3));

% simulate
R_res = zeros(3,3,1000,Nt);
x_res = zeros(3,1000,Nt);
R_res(:,:,:,1) = gather(R(:,:,1:1000));
x_res(:,:,1) = gather(x(:,1:1000));

for nt = 1:Nt-1
    tic;
    
    [R,x] = LGVI(R,x,1/sf,m,rho,J,g);
    R_res(:,:,:,nt+1) = gather(R(:,:,1:1000));
    x_res(:,:,nt+1) = gather(x(:,1:1000));
    
    [stat.ER(:,:,nt+1),stat.Ex(:,nt+1),stat.Varx(:,:,nt+1),stat.EvR(:,nt+1),stat.ExvR(:,:,nt+1),stat.EvRvR(:,:,nt+1),...
        MFG.U(:,:,nt+1),MFG.S(:,:,nt+1),MFG.V(:,:,nt+1),MFG.P(:,:,nt+1),MFG.Miu(:,nt+1),MFG.Sigma(:,:,nt+1)] = ...
        get_stat(gather(R),gather(x),MFG.S(:,:,nt));
    
    toc;
end

rmpath('../matrix Fisher');
rmpath('../rotation3d');

end


function [ R, x ] = LGVI( R, x, dt, m, rho, J, g)

Ns = size(R,3);

x = gpuArray(x);
R = gpuArray(R);

M = -m*g*permute(cat(1,rho(2)*R(3,3,:)-rho(3)*R(3,2,:),...
    rho(3)*R(3,1,:)-rho(1)*R(3,3,:),...
    rho(1)*R(3,2,:)-rho(2)*R(3,1,:)),[1,3,2]);

dR = gpuArray.zeros(3,3,Ns);
A = dt*J*x+dt^2/2*M;

% G
normv = @(v) sqrt(sum(v.^2,1));
Gv = @(v) sin(normv(v))./normv(v).*(J*v)+...
    (1-cos(normv(v)))./sum(v.^2,1).*cross(v,J*v);

% Jacobian of G
DGv = @(v) permute((cos(normv(v)).*normv(v)-sin(normv(v)))./normv(v).^3,[1,3,2]).*...
    pagefun(@mtimes,permute(J*v,[1,3,2]),permute(v,[3,1,2])) + ...
    permute(sin(normv(v))./normv(v),[1,3,2]).*J + ...
    permute((sin(normv(v)).*normv(v)-2*(1-cos(normv(v))))./sum(v.^2,1).^2,[1,3,2]).*...
    pagefun(@mtimes,permute(cross(v,J*v),[1,3,2]),permute(v,[3,1,2])) + ...
    permute((1-cos(normv(v)))./sum(v.^2,1),[1,3,2]).*(-hat(J*v)+pagefun(@mtimes,hat(v),J));

% GPU matrix exponential
expRot = @(v) eye(3) + permute(sin(normv(v))./normv(v),[1,3,2]).*hat(v) + ...
    permute((1-cos(normv(v)))./sum(v.^2,1),[1,3,2]).*pagefun(@mtimes,hat(v),hat(v));

% initializa Newton method
v = gpuArray.ones(3,Ns)*1e-5;

% tolerance
epsilon = 1e-5;

% step size
alpha = 1;

% Newton method
n_finished = 0;
ind = 1:Ns;

n_step = 0;
while n_finished < Ns
    ind_finished = find(normv(A-Gv(v))<epsilon);
    dR(:,:,ind(ind_finished)) = expRot(v(:,ind_finished));
    ind = setdiff(ind,ind(ind_finished));
    n_finished = n_finished+length(ind_finished);
    
    v(:,ind_finished) = [];
    A(:,ind_finished) = [];
    v = v + alpha*permute(pagefun(@mtimes,pagefun(@inv,DGv(v)),permute(A-Gv(v),[1,3,2])),[1,3,2]);
    
    n_step = n_step+1;
end

R = mulRot(R,dR);
    
M2 = -m*g*permute(cat(1,rho(2)*R(3,3,:)-rho(3)*R(3,2,:),...
    rho(3)*R(3,1,:)-rho(1)*R(3,3,:),...
    rho(1)*R(3,2,:)-rho(2)*R(3,1,:)),[1,3,2]);
x = J^-1*(permute(pagefun(@mtimes,permute(dR,[2,1,3]),permute(J*x,[1,3,2])),[1,3,2]) + ...
    dt/2*permute(pagefun(@mtimes,permute(dR,[2,1,3]),permute(M,[1,3,2])),[1,3,2]) + dt/2*M2);

end


function [ ER, Ex, Varx, EvR, ExvR, EvRvR, U, S, V, P, Miu, Sigma ] = get_stat(R, x, S)

Ns = size(R,3);

ER = sum(R,3)/Ns;
Ex = sum(x,2)/Ns;
Varx = sum(permute(x,[1,3,2]).*permute(x,[3,1,2]),3)/Ns - Ex*Ex.';

[U,D,V] = psvd(ER);
s = pdf_MF_M2S(diag(D),diag(S));
S = diag(s);

Q = mulRot(U',mulRot(R,V));
vR = permute(cat(1,s(2)*Q(3,2,:)-s(3)*Q(2,3,:),...
    s(3)*Q(1,3,:)-s(1)*Q(3,1,:),s(1)*Q(2,1,:)-s(2)*Q(1,2,:)),[1,3,2]);

EvR = sum(vR,2)/Ns;
ExvR = sum(permute(x,[1,3,2]).*permute(vR,[3,1,2]),3)/Ns;
EvRvR = sum(permute(vR,[1,3,2]).*permute(vR,[3,1,2]),3)/Ns;

covxx = Varx;
covxvR = ExvR-Ex*EvR.';
covvRvR = EvRvR-EvR*EvR.';

P = covxvR*covvRvR^-1;
Miu = Ex-P*EvR;
Sigma = covxx-P*covxvR.'+P*(trace(S)*eye(3)-S)*P.';

end

