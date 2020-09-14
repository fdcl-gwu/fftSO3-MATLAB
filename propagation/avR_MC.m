clear;
close all;

addpath('../rotation3d');
addpath('../matrix Fisher');
addpath('..');

% time
sf = 10;
T = 1;

t = 0:1/sf:T;
Nt = T*sf+1;

% number of samples
N = 10000;
R = zeros(3,3,N,Nt);

% angular velocity
k_o = 1;

% initial condition
s0 = [10,10,10];
initR = expRot(pi/2*[0,0,1]);
R(:,:,:,1) = pdf_MF_sampling(diag(s0)*initR,N);

%% propagate
for nt = 1:Nt-1
    trR = permute(R(1,1,:,nt)+R(2,2,:,nt)+R(3,3,:,nt),[1,3,2]);
    omega = [-k_o*trR;k_o*trR;-k_o*trR];
    
    R(:,:,:,nt+1) = mulRot(R(:,:,:,nt),expRot(omega/sf));
end

%% match to matrix Fisher and plot
% expectation
ER = zeros(3,3,Nt);
for nt = 1:Nt
    ER(:,:,nt) = mean(R(:,:,:,nt),3);
end

% match to matrix Fisher
U = zeros(3,3,Nt);
V = zeros(3,3,Nt);
S = zeros(3,Nt);

for nt = 1:Nt
    [U(:,:,nt),D,V(:,:,nt)] = psvd(ER(:,:,nt));
    if nt==1
        S(:,nt) = pdf_MF_M2S(diag(D),s0.');
    else
        S(:,nt) = pdf_MF_M2S(diag(D),S(:,nt-1));
    end
end

% spherical grid
Nt1 = 100;
Nt2 = 100;
theta1 = linspace(-pi,pi,Nt2);
theta2 = linspace(0,pi,Nt1);
s1 = cos(theta1)'.*sin(theta2);
s2 = sin(theta1)'.*sin(theta2);
s3 = repmat(cos(theta2),Nt1,1);

% color map
color = zeros(100,100,3,Nt);
for nt = 1:Nt
    cF = pdf_MF_normal(S(:,nt));
    F = U(:,:,nt)*diag(S(:,nt))*V(:,:,nt).';
    
    for i = 1:3
        j = mod(i,3)+1;
        k = mod(i+1,3)+1;
        
        for m = 1:100
            for n = 1:100
                r = [s1(m,n);s2(m,n);s3(m,n)];
                
                s_p = eig(F(:,[j,k]).'*(eye(3)-r*r.')*F(:,[j,k]));
                s_p1 = sqrt(s_p(1));
                s_p2 = sqrt(s_p(2));
                
                color(m,n,i,nt) = exp(F(:,i).'*r)/cF*besseli(0,...
                    s_p1+sign(r.'*cross(F(:,j),F(:,k)))*s_p2);
            end
        end
    end
end

color = real(color);

% plot
for nt = 1:Nt
    figure(nt);
    surf(s1,s2,s3,sum(color(:,:,:,nt),3),'LineStyle','none');
    
    axis equal;
    view([1,1,1]);
end

rmpath('../rotation3d');
rmpath('../matrix Fisher');
rmpath('..');


