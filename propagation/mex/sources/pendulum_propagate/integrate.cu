#include "integrate.cuh"

#include <stdio.h>
#include <iostream>

__global__ void flip_shift(const cuDoubleComplex* X, cuDoubleComplex* X_ijk, const int is, const int js, const int ks, const Size_F* size_F)
{
	int i = blockIdx.x*blockDim.x + threadIdx.x;
	int j = blockIdx.y*blockDim.y + threadIdx.y;
	int k = blockIdx.z*blockDim.z + threadIdx.z;

	if (i < size_F[0].const_2Bx && j < size_F[0].const_2Bx && k < size_F[0].const_2Bx) {
		int iout = is-i;
		if (iout < 0)
			iout += size_F[0].const_2Bx;
		else if (iout >= size_F[0].const_2Bx)
			iout -= size_F[0].const_2Bx;

		int jout = js-j;
		if (jout < 0)
			jout += size_F[0].const_2Bx;
		else if (jout >= size_F[0].const_2Bx)
			jout -= size_F[0].const_2Bx;

		int kout = ks-k;
		if (kout < 0)
			kout += size_F[0].const_2Bx;
		else if (kout >= size_F[0].const_2Bx)
			kout -= size_F[0].const_2Bx;

		int X_ind = i + j*size_F[0].const_2Bx + k*size_F[0].const_2Bxs;
		int X_ijk_ind = iout + jout*size_F[0].const_2Bx + kout*size_F[0].const_2Bxs;

		for (int m = 0; m < 3; m++)
			X_ijk[X_ijk_ind + m*size_F[0].nx] = X[X_ind + m*size_F[0].nx];
	}
}

__global__ void addup_F(cuDoubleComplex* dF, Size_F* size_F)
{
	int ind1 = threadIdx.x + blockIdx.x*blockDim.x;
	if (ind1 < size_F[0].nTot_splitx) {
		int ind2 = ind1 + size_F[0].nTot_splitx;
		int ind3 = ind2 + size_F[0].nTot_splitx;

		dF[ind1] = cuCadd(dF[ind1], dF[ind2]);
		dF[ind1] = cuCadd(dF[ind1], dF[ind3]);
	}
}

__global__ void add_F(cuDoubleComplex* dF, const cuDoubleComplex* dF_temp, const Size_F* size_F)
{
	int ind = threadIdx.x + blockIdx.x*blockDim.x;
	if (ind < size_F[0].nTot_splitx)
		dF[ind] = cuCadd(dF[ind], dF_temp[ind]);
}

__global__ void mulImg_FR(cuDoubleComplex* dF, const double c, const int nR, const Size_F* size_F)
{
	int ind = threadIdx.x + blockIdx.x*blockDim.x;
	if (ind < nR) {
		double y = dF[ind].y;
		dF[ind].y = dF[ind].x * c;
		dF[ind].x = -y * c;
	}
}

__global__ void kron_FMR(double* FMR_real, double* FMR_imag, const cuDoubleComplex* F, const cuDoubleComplex* MR,
	const int ind_F_cumR, const int ind_MR_cumR, const bool iswrapped, const int c2l1p1, const int c2l2p1, const Size_F* size_F)
{
	if (!iswrapped) {
		int ind_F = threadIdx.x + threadIdx.y*blockDim.x + ind_F_cumR + blockIdx.z*size_F->nR_compact;
		int ind_MR = blockIdx.x + blockIdx.y*gridDim.x + ind_MR_cumR;
	
		int i_FMR = blockIdx.x + threadIdx.x*gridDim.x;
		int j_FMR = blockIdx.y + threadIdx.y*gridDim.y;
		int m = blockDim.x*gridDim.x;

		int ind_FMR = i_FMR + j_FMR*m + blockIdx.z*m*m;

		FMR_real[ind_FMR] = F[ind_F].x*MR[ind_MR].x - F[ind_F].y*MR[ind_MR].y;
		FMR_imag[ind_FMR] = F[ind_F].x*MR[ind_MR].y + F[ind_F].y*MR[ind_MR].x;
	} else {
		int i_MR = (int) blockIdx.x / c2l2p1;
		int r_F = blockIdx.x % c2l2p1;
		int i_F = threadIdx.x + r_F*32;

		int j_MR = (int) blockIdx.y / c2l2p1;
		r_F = blockIdx.y % c2l2p1;
		int j_F = threadIdx.x + r_F*32;

		if (i_F < c2l1p1 && j_F < c2l1p1) {
			int ind_F = i_F + j_F*c2l1p1 + ind_F_cumR + blockIdx.z*size_F->nR_compact;
			int ind_MR = i_MR + j_MR*c2l2p1 + ind_MR_cumR;

			int i_FMR = i_MR + i_F*c2l2p1;
			int j_FMR = j_MR + j_F*c2l2p1;
			int m = c2l1p1*c2l2p1;

			int ind_FMR = i_FMR + j_FMR*m + blockIdx.z*m*m;

			FMR_real[ind_FMR] = F[ind_F].x*MR[ind_MR].x - F[ind_F].y*MR[ind_MR].y;
			FMR_imag[ind_FMR] = F[ind_F].x*MR[ind_MR].y + F[ind_F].y*MR[ind_MR].x;
		}
	}
}

__global__ void add_FMR(cuDoubleComplex* dF, const double* FMR_real, const double* FMR_imag, const int ind_cumR, const int c2lp1s, const Size_F* size_F)
{
	int ind_dF = threadIdx.x + blockIdx.x*512;
	if (ind_dF < c2lp1s) {
		int ind_FMR = ind_dF + blockIdx.y*c2lp1s;
		ind_dF += ind_cumR + blockIdx.y*size_F->nR_compact;

		dF[ind_dF].x += FMR_real[ind_FMR];
		dF[ind_dF].y += FMR_imag[ind_FMR];
	}
}

__global__ void mulImg_FTot(cuDoubleComplex* dF, const double* c, const int dim, const int k, const Size_F* size_F)
{
	int ind_R = threadIdx.x + blockIdx.x*blockDim.x;
	if (ind_R < size_F->nR_compact) {
		int ijk[3] = {};
		ijk[0] = blockIdx.y;
		ijk[1] = blockIdx.z;
		ijk[2] = k;

		int ind_dF = ind_R + (ijk[0] + ijk[1]*size_F->const_2Bx)*size_F->nR_compact;

		double y = dF[ind_dF].y;
		dF[ind_dF].y = dF[ind_dF].x * c[ijk[dim]];
		dF[ind_dF].x = -y * c[ijk[dim]];
	}
}

__global__ void integrate_Fnew(cuDoubleComplex* Fnew, const cuDoubleComplex* Fold, const cuDoubleComplex* dF, const double dt, const Size_F* size_F)
{
	int ind = threadIdx.x + blockIdx.x*blockDim.x;
	if (ind < size_F[0].nTot_splitx)
	{
		Fnew[ind].x = Fold[ind].x + dt*dF[ind].x;
		Fnew[ind].y = Fold[ind].y + dt*dF[ind].y;
	}
}

__host__ void modify_F(const cuDoubleComplex* F, cuDoubleComplex* F_modify, bool reduce,Size_F* size_F)
{
	if (reduce) {
		int ind_F_reduced = 0;
		for (int k = 0; k < size_F[0].const_2Bx; k++) {
			for (int j = 0; j < size_F[0].const_2Bx; j++) {
				for (int i = 0; i < size_F[0].const_2Bx; i++) {
					for (int l = 0; l <= size_F[0].lmax; l++) {
						for (int m = -l; m <= l; m++) {
							for (int n = -l; n <= l; n++) {
								int ind_F = n+size_F[0].lmax + (m+size_F[0].lmax)*size_F[0].l_cum0 + 
									l*size_F[0].l_cum1 + i*size_F[0].l_cum2 + j*size_F[0].l_cum3 + k*size_F[0].l_cum4;
								F_modify[ind_F_reduced] = F[ind_F];

								ind_F_reduced++;
							}
						}
					}
				}
			}
		}
	} else {
		int ind_F_reduced = 0;
		for (int k = 0; k < size_F[0].const_2Bx; k++) {
			for (int j = 0; j < size_F[0].const_2Bx; j++) {
				for (int i = 0; i < size_F[0].const_2Bx; i++) {
					for (int l = 0; l <= size_F[0].lmax; l++) {
						for (int m = -l; m <= l; m++) {
							for (int n = -l; n <= l; n++) {
								int ind_F = n+size_F[0].lmax + (m+size_F[0].lmax)*size_F[0].l_cum0 + 
									l*size_F[0].l_cum1 + i*size_F[0].l_cum2 + j*size_F[0].l_cum3 + k*size_F[0].l_cum4;
								F_modify[ind_F] = F[ind_F_reduced];

								ind_F_reduced++;
							}
						}
					}
				}
			}
		}
	}
}

__host__ void permute_F(cuDoubleComplex* F, bool R_first, Size_F* size_F)
{
	cuDoubleComplex* Fp = new cuDoubleComplex[size_F->nTot_compact];
	if (R_first) {
		for (int iR = 0; iR < size_F->nR_compact; iR++) {
			for (int i = 0; i < size_F->const_2Bx; i++) {
				for (int j = 0; j < size_F->const_2Bx; j++) {
					for (int k = 0; k < size_F->const_2Bx; k++) {
						int ind_F = i + j*size_F->const_2Bx + k*size_F->const_2Bxs + iR*size_F->nx;
						int ind_Fp = iR + (i + j*size_F->const_2Bx + k*size_F->const_2Bxs) * size_F->nR_compact;

						Fp[ind_Fp] = F[ind_F];
					}
				}
			}
		}
	} else {
		for (int iR = 0; iR < size_F->nR_compact; iR++) {
			for (int i = 0; i < size_F->const_2Bx; i++) {
				for (int j = 0; j < size_F->const_2Bx; j++) {
					for (int k = 0; k < size_F->const_2Bx; k++) {
						int ind_F = iR + (i + j*size_F->const_2Bx + k*size_F->const_2Bxs) * size_F->nR_compact;
						int ind_Fp = i + j*size_F->const_2Bx + k*size_F->const_2Bxs + iR*size_F->nx;

						Fp[ind_Fp] = F[ind_F];
					}
				}
			}
		}
	}

	memcpy(F, Fp, size_F->nTot_compact * sizeof(cuDoubleComplex));
	delete[] Fp;
}

__host__ void modify_u(const cuDoubleComplex* u, cuDoubleComplex* u_modify, Size_F* size_F)
{
	int ind_u_reduced = 0;
	for (int i = 0; i < 3; i++) {
		for (int l = 0; l <= size_F[0].lmax; l++) {
			for (int m = -l; m <= l; m++) {
				for (int n = -l; n <= l; n++) {
					int ind_u = n+size_F[0].lmax + (m+size_F[0].lmax)*size_F[0].l_cum0 + l*size_F[0].l_cum1 + i*size_F[0].l_cum2;
					u_modify[ind_u_reduced] = u[ind_u];

					ind_u_reduced++;
				}
			}
		}
	}
}

__host__ void deriv_x(double* c, const int n, const int B, const double L)
{
	if (n < B)
		*c = 2*PI*n/L;
	else if (n == B)
		*c = 0;
	else
		*c = 2*PI*(n-2*B)/L;
}

__host__ void get_blocksize(dim3* gridsize, dim3* blocksize, bool* iswrapped, const int l1, const int l2, const Size_F* size_F)
{
	if (2*l1+1 <= 32) {
		blocksize->x = 2*l1+1;
		blocksize->y = blocksize->x;

		gridsize->x = 2*l2+1;
		gridsize->y = gridsize->x;
		gridsize->z = size_F->const_2Bx;

		*iswrapped = false;
	} else {
		blocksize->x = 32;
		blocksize->y = 32;

		gridsize->x = ((int) l1/32+1)*(2*l2+1);
		gridsize->y = gridsize->x;
		gridsize->z = size_F->const_2Bx;

		*iswrapped = true;
	}
}

__host__ void cudaErrorHandle(const cudaError_t& err)
{
	if (err != cudaSuccess) {
		std::cout << "Cuda Error: " << cudaGetErrorString(err) << std::endl;
	}
}

__host__ void cutensorErrorHandle(const cutensorStatus_t& err)
{
	if (err != CUTENSOR_STATUS_SUCCESS) {
		std::cout << "cuTensor Error: " << cutensorGetErrorString(err) << std::endl;
	}
}

__host__ void cublasErrorHandle(const cublasStatus_t& err)
{
	if (err != CUBLAS_STATUS_SUCCESS) {
		std::cout << "cuBlas Error: " << err << std::endl;
	}
}

__host__ void cutensor_initialize(cutensorHandle_t* handle, cutensorContractionPlan_t* plan, size_t* worksize,
	void* Fold_dev, void* X_dev, void* dF_dev, const int nR_split, const Size_F* size_F)
{
	int mode_Fold[4] = {'i','j','k','r'};
	int mode_X[4] = {'i','j','k','p'};
	int mode_dF[2] = {'r','p'};

	int64_t extent_Fold[4] = {size_F->const_2Bx, size_F->const_2Bx, size_F->const_2Bx, nR_split};
	int64_t extent_X[4] = {size_F->const_2Bx, size_F->const_2Bx, size_F->const_2Bx, 3};
	int64_t extent_dF[2] = {nR_split, 3};

	cutensorTensorDescriptor_t desc_Fold;
	cutensorTensorDescriptor_t desc_X;
	cutensorTensorDescriptor_t desc_dF;
	cutensorErrorHandle(cutensorInitTensorDescriptor(handle, &desc_Fold,
		4, extent_Fold, NULL, CUDA_C_64F, CUTENSOR_OP_IDENTITY));
	cutensorErrorHandle(cutensorInitTensorDescriptor(handle, &desc_X,
		4, extent_X, NULL, CUDA_C_64F, CUTENSOR_OP_IDENTITY));
	cutensorErrorHandle(cutensorInitTensorDescriptor(handle, &desc_dF,
		2, extent_dF, NULL, CUDA_C_64F, CUTENSOR_OP_IDENTITY));

	uint32_t alignmentRequirement_Fold;
	uint32_t alignmentRequirement_X;
	uint32_t alignmentRequirement_temp;
	cutensorErrorHandle(cutensorGetAlignmentRequirement(handle,
		Fold_dev, &desc_Fold, &alignmentRequirement_Fold));
	cutensorErrorHandle(cutensorGetAlignmentRequirement(handle,
		X_dev, &desc_X, &alignmentRequirement_X));
	cutensorErrorHandle(cutensorGetAlignmentRequirement(handle,
		dF_dev, &desc_dF, &alignmentRequirement_temp));

	cutensorContractionDescriptor_t desc;
	cutensorErrorHandle(cutensorInitContractionDescriptor(handle, &desc,
		&desc_Fold, mode_Fold, alignmentRequirement_Fold,
		&desc_X, mode_X, alignmentRequirement_X,
		&desc_dF, mode_dF, alignmentRequirement_temp,
		&desc_dF, mode_dF, alignmentRequirement_temp,
		CUTENSOR_COMPUTE_64F));

	cutensorContractionFind_t find;
	cutensorErrorHandle(cutensorInitContractionFind(handle, &find, CUTENSOR_ALGO_DEFAULT));

	cutensorErrorHandle(cutensorContractionGetWorkspace(handle, &desc, &find, CUTENSOR_WORKSPACE_RECOMMENDED, worksize));

	cutensorErrorHandle(cutensorInitContractionPlan(handle, plan, &desc, &find, *worksize));
}

__host__ void init_Size_F(Size_F* size_F, int BR, int Bx)
{
	size_F->BR = BR;
	size_F->Bx = Bx;
	size_F->lmax = BR-1;

	size_F->nR = (2*size_F->lmax+1) * (2*size_F->lmax+1) * (size_F->lmax+1);
	size_F->nx = (2*Bx) * (2*Bx) * (2*Bx);
	size_F->nTot = size_F->nR * size_F->nx;

	size_F->nR_compact = (size_F->lmax+1) * (2*size_F->lmax+1) * (2*size_F->lmax+3) / 3;
	size_F->nTot_compact = size_F->nR_compact * size_F->nx;

	size_F->const_2Bx = 2*Bx;
	size_F->const_2Bxs = (2*Bx) * (2*Bx);
	size_F->const_2lp1 = 2*size_F->lmax+1;
	size_F->const_lp1 = size_F->lmax+1;
	size_F->const_2lp1s = (2*size_F->lmax+1) * (2*size_F->lmax+1);

	size_F->l_cum0 = size_F->const_2lp1;
	size_F->l_cum1 = size_F->l_cum0*size_F->const_2lp1;
	size_F->l_cum2 = size_F->l_cum1*size_F->const_lp1;
	size_F->l_cum3 = size_F->l_cum2*size_F->const_2Bx;
	size_F->l_cum4 = size_F->l_cum3*size_F->const_2Bx;

	size_F->ns = size_F->const_2lp1;
	size_F->nR_split = (int) size_F->nR_compact / (size_F->ns-1);
	size_F->nR_remainder = size_F->nR_compact % (size_F->ns-1);

	size_F->nTot_splitx = size_F->nR_compact * size_F->const_2Bxs;
	size_F->nTot_splitx2 = size_F->nR_compact * size_F->const_2Bx;
}

