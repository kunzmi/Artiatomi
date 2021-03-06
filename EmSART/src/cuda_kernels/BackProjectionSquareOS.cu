//  Copyright (c) 2018, Michael Kunz and Frangakis Lab, BMLS,
//  Goethe University, Frankfurt am Main.
//  All rights reserved.
//  http://kunzmi.github.io/Artiatomi
//  
//  This file is part of the Artiatomi package.
//  
//  Artiatomi is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//  
//  Artiatomi is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//  
//  You should have received a copy of the GNU General Public License
//  along with Artiatomi. If not, see <http://www.gnu.org/licenses/>.
//  
////////////////////////////////////////////////////////////////////////


/**********************************************
*
* CUDA SART FRAMEWORK
* 2009,2010 Michael Kunz, Lukas Marsalek
* 
*
* BackProjectionSquareOS.cu
* CVR back projection kernel with squared 
* oversampling pattern
*
**********************************************/
#ifndef BACKPROJECTIONSQUAREOS_CU
#define BACKPROJECTIONSQUAREOS_CU

#define _SIZE_T_DEFINED
#ifndef __CUDACC__
#define __CUDACC__
#endif
#ifndef __cplusplus
#define __cplusplus
#endif

#include <cuda.h>
#include "cutil.h"
#include "cutil_math.h"
#include <device_launch_parameters.h>
#include <texture_fetch_functions.h>
#include "float.h"
#include <builtin_types.h>
#include <vector_functions.h>
#include <device_functions.h>

#include "Constants.h"
#include "DeviceVariables.cuh"

//#include <curand_kernel.h>

//#define CONST_LENGTH_MODE
#define PRECISE_LENGTH_MODE

#define SM20 1
#if __CUDA_ARCH__ >= 200
//#warning compiling for SM20
#else
#if __CUDA_ARCH__ >= 130
//#warning compiling for SM13
#endif
#endif






//#define SPLINES
#ifdef SPLINES


#define Pole (sqrt(3.0f)-2.0f)  //pole for cubic b-spline
 
//--------------------------------------------------------------------------
// Local GPU device procedures
//--------------------------------------------------------------------------
__host__ __device__ float InitialCausalCoefficient(
	float* c,			// coefficients
	uint DataLength,	// number of coefficients
	int step)			// element interleave in bytes
{
	const uint Horizon = min(12, DataLength);

	// this initialization corresponds to clamping boundaries
	// accelerated loop
	float zn = Pole;
	float Sum = *c;
	for (uint n = 0; n < Horizon; n++) {
		Sum += zn * *c;
		zn *= Pole;
		c = (float*)((uchar*)c + step);
	}
	return(Sum);
}

__host__ __device__ float InitialAntiCausalCoefficient(
	float* c,			// last coefficient
	uint DataLength,	// number of samples or coefficients
	int step)			// element interleave in bytes
{
	// this initialization corresponds to clamping boundaries
	return((Pole / (Pole - 1.0f)) * *c);
}

__host__ __device__ void ConvertToInterpolationCoefficients(
	float* coeffs,		// input samples --> output coefficients
	uint DataLength,	// number of samples or coefficients
	int step)			// element interleave in bytes
{
	// compute the overall gain
	const float Lambda = (1.0f - Pole) * (1.0f - 1.0f / Pole);

	// causal initialization
	float* c = coeffs;
	float previous_c;  //cache the previously calculated c rather than look it up again (faster!)
	*c = previous_c = Lambda * InitialCausalCoefficient(c, DataLength, step);
	// causal recursion
	for (uint n = 1; n < DataLength; n++) {
		c = (float*)((uchar*)c + step);
		*c = previous_c = Lambda * *c + Pole * previous_c;
	}
	// anticausal initialization
	*c = previous_c = InitialAntiCausalCoefficient(c, DataLength, step);
	// anticausal recursion
	for (int n = DataLength - 2; 0 <= n; n--) {
		c = (float*)((uchar*)c - step);
		*c = previous_c = Pole * (previous_c - *c);
	}
}

extern "C"
__global__ void SamplesToCoefficients2DX(
	float* image,		// in-place processing
	uint pitch,			// width in bytes
	uint width,			// width of the image
	uint height)		// height of the image
{
	// process lines in x-direction
	const uint y = blockIdx.x * blockDim.x + threadIdx.x;
	float* line = (float*)((uchar*)image + y * pitch);  //direct access

	ConvertToInterpolationCoefficients(line, width, sizeof(float));
}

extern "C"
__global__ void SamplesToCoefficients2DY(
	float* image,		// in-place processing
	uint pitch,			// width in bytes
	uint width,			// width of the image
	uint height)		// height of the image
{
	// process lines in x-direction
	const uint x = blockIdx.x * blockDim.x + threadIdx.x;
	float* line = image + x;  //direct access

	ConvertToInterpolationCoefficients(line, height, pitch);
}



// Cubic B-spline function
// The 3rd order Maximal Order and Minimum Support function, that it is maximally differentiable.
inline __host__ __device__ float bspline(float t)
{
	t = fabs(t);
	const float a = 2.0f - t;

	if (t < 1.0f) return 2.0f/3.0f - 0.5f*t*t*a;
	else if (t < 2.0f) return a*a*a / 6.0f;
	else return 0.0f;
}


//! Bicubic interpolated texture lookup, using unnormalized coordinates.
//! Straight forward implementation, using 16 nearest neighbour lookups.
//! @param tex  2D texture
//! @param x  unnormalized x texture coordinate
//! @param y  unnormalized y texture coordinate
__device__ float cubicTex2DSimple(texture<float, 2, cudaReadModeElementType> _tex, float x, float y)
{
	// transform the coordinate from [0,extent] to [-0.5, extent-0.5]
	const float2 coord_grid = make_float2(x - 0.5f, y - 0.5f);
	float2 index;
	index.x = floor(coord_grid.x);
	index.y = floor(coord_grid.y);
	float2 fraction;
	fraction.x = coord_grid.x - index.x;
	fraction.y = coord_grid.y - index.y;
	index.x += 0.5f;  //move from [-0.5, extent-0.5] to [0, extent]
	index.y += 0.5f;  //move from [-0.5, extent-0.5] to [0, extent]

	float result = 0.0f;
	for (float y=-1; y < 2.5f; y++)
	{
		float bsplineY = bspline(y-fraction.y);
		float v = index.y + y;
		for (float x=-1; x < 2.5f; x++)
		{
			float bsplineXY = bspline(x-fraction.x) * bsplineY;
			float u = index.x + x;
			result += bsplineXY * tex2D(_tex, u, v);
		}
	}
	return result;
}























#endif



// transform vector by matrix
__device__
void MatrixVector3Mul(float4x4 M, float3* v)
{
	float3 erg;
	erg.x = M.m[0].x * v->x + M.m[0].y * v->y + M.m[0].z * v->z + 1.f * M.m[0].w;
	erg.y = M.m[1].x * v->x + M.m[1].y * v->y + M.m[1].z * v->z + 1.f * M.m[1].w;
	erg.z = M.m[2].x * v->x + M.m[2].y * v->y + M.m[2].z * v->z + 1.f * M.m[2].w;
	*v = erg;
}

extern volatile __shared__ unsigned char sBuffer[];


#ifdef SM20
surface<void, cudaSurfaceType3D> surfref;
#endif


extern "C"
__global__ 
void backProjection(int proj_x, int proj_y, float lambda, int maxOverSample, float maxOverSampleInv, float* img, int stride, float distMin, float distMax)
{
	float3 ray;
	float3 borderMin;
	float3 borderMax;
	float3 hitPoint;
	float3 c_source;

	//curandState state;


	int4 pixelBorders; //--> x = x.min; y = x.max; z = y.min; v = y.max   	
	
	// index to access shared memory, e.g. thread linear address in a block
	const unsigned int index2 = (threadIdx.z * blockDim.x * blockDim.y) + (threadIdx.y * blockDim.x) + threadIdx.x;	

	// integer voxel coordinates
	//unsigned long long int voxelIndex;
	
	//we are using -use_fast_math flag! Only 24 bit integer multiplication = no 512 sized volume index can be computed
	//hack: use long long int data type
	//voxelIndex = (unsigned long long int)blockIdx.x * (unsigned long long int)blockDim.x + (unsigned long long int)threadIdx.x + (unsigned long long int)(blockDim.x * gridDim.x) * (unsigned long long int)(blockIdx.y * blockDim.y + (unsigned long long int)threadIdx.y);
	
	//compute x,y,z indiced
	//unsigned int z = (unsigned int)floor((double)voxelIndex / (double)c_volumeDim_x_quarter / (double)c_volumeDim.y) ;
	//unsigned int y = (unsigned int)floor((double)((double)voxelIndex - (double)z * (double)c_volumeDim_x_quarter * (double)c_volumeDim.y) / (double)c_volumeDim_x_quarter);
	//unsigned int x = (unsigned int)(voxelIndex - (double)z * (double)c_volumeDim_x_quarter * (double)c_volumeDim.y - (double)y * (double)c_volumeDim_x_quarter);	
	
	unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	const unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
	const unsigned int z = blockIdx.z * blockDim.z + threadIdx.z;

	//curand_init(1234, x + (unsigned long long)y * c_volumeDim_x_quarter  + (unsigned long long)z * c_volumeDim_x_quarter * c_volumeDim.y, 0, &state);
	
	//voxelIndex = x + (unsigned long)y * c_volumeDim_x_quarter  + (unsigned long)z * c_volumeDim_x_quarter * c_volumeDim.y;

	if (x >= c_volumeDim_x_quarter || y >= c_volumeDim.y || z >= c_volumeDim.z) return;

	//summed up distance per voxel in voxelBlock in shared memory
	volatile float4* distanceD = (float4*)(sBuffer);
	
	//Correction term per voxel in shared memory
	volatile float4* voxelD = distanceD + blockDim.x * blockDim.y * blockDim.z;
	//volatile float4* voxelD = (float4*)(sBuffer);
	
	
	float4 voxelBlock;

	//float3 detectorNormal;
	float3 MC_bBoxMin;
	float3 MC_bBoxMax;
	float t;
	
	float t_in, t_out;
	float3 tEntry;
	float3 tExit;
	float3 tmin, tmax;
	float pixel_y, pixel_x;	

	//read voxel values from global device memory and normalize them
	//ushort4 temp = vol2[voxelIndex];
	//voxelBlock.x = temp.x / 65535.0f;
	//voxelBlock.y = temp.y / 65535.0f;
	//voxelBlock.z = temp.z / 65535.0f;
	//voxelBlock.w = temp.w / 65535.0f;
	//ushort4 temp = vol2[voxelIndex];
	#ifdef SM20
	surf3Dread(&voxelBlock.x, surfref, x * 4 * 4 + 0, y, z);
	surf3Dread(&voxelBlock.y, surfref, x * 4 * 4 + 4, y, z);
	surf3Dread(&voxelBlock.z, surfref, x * 4 * 4 + 8, y, z);
	surf3Dread(&voxelBlock.w, surfref, x * 4 * 4 + 12, y, z);
	#else
	voxelBlock = vol2[voxelIndex];
	#endif


	//adopt x coordinate to single voxels, not voxelBlocks
	x = x * 4;

	//MacroCell bounding box:
	MC_bBoxMin.x = c_bBoxMin.x + (x) * c_voxelSize.x;
	MC_bBoxMin.y = c_bBoxMin.y + (y) * c_voxelSize.y;
	MC_bBoxMin.z = c_bBoxMin.z + (z) * c_voxelSize.z;
	MC_bBoxMax.x = c_bBoxMin.x + ( x + 5) * c_voxelSize.x;
	MC_bBoxMax.y = c_bBoxMin.y + ( y + 1) * c_voxelSize.y;
	MC_bBoxMax.z = c_bBoxMin.z + ( z + 1) * c_voxelSize.z;

	
	//find maximal projection on detector:
	borderMin = make_float3(FLT_MAX, FLT_MAX, FLT_MAX);
	borderMax = make_float3(-200000.f, -200000.f, -200000.f);


	//The loop has been manually unrolled: nvcc cannot handle inner loops
	//first corner
	//ray.x = -c_projNorm.x;
	//ray.y = -c_projNorm.y;
	//ray.z = -c_projNorm.z;

	//ray = normalize(ray);
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);

	if (!(t >= distMin && t < distMax)) return;

	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//second corner
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//third corner
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//fourth corner
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//fifth corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//sixth corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//seventh corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//eighth corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//get largest area
	MC_bBoxMin = fminf(borderMin, borderMax);
	MC_bBoxMax = fmaxf(borderMin, borderMax);

	//swap x values if opposite projection direction
//	if (c_projNorm.y * c_projNorm.z >= 0)
	{
//		float ttemp = MC_bBoxMin.x;
//		MC_bBoxMin.x = MC_bBoxMax.x;
//		MC_bBoxMax.x = ttemp;
	}
//	else
	if (c_projNorm.x <= 0)
	{
		float temp = MC_bBoxMin.x;
		MC_bBoxMin.x = MC_bBoxMax.x;
		MC_bBoxMax.x = temp;
		//temp = MC_bBoxMin.y;
		//MC_bBoxMin.y = MC_bBoxMax.y;
		//MC_bBoxMax.y = temp;
	}
	//if (c_projNorm.x * c_projNorm.y >= 0) 
	//{
	//	float temp = MC_bBoxMin.y;
	//	MC_bBoxMin.y = MC_bBoxMax.y;
	//	MC_bBoxMax.y = temp;

	//	
	//}
	//else
	//{
	//	float ttemp = MC_bBoxMin.x;
	//	MC_bBoxMin.x = MC_bBoxMax.x;
	//	MC_bBoxMax.x = ttemp;
	//}

	//Convert global coordinated to projection pixel indices
	MatrixVector3Mul(c_DetectorMatrix, &MC_bBoxMin);    
	MatrixVector3Mul(c_DetectorMatrix, &MC_bBoxMax);

	hitPoint = fminf(MC_bBoxMin, MC_bBoxMax);
	//--> pixelBorders.x = x.min; pixelBorders.z = y.min;
	pixelBorders.x = floor(hitPoint.x); 
	pixelBorders.z = floor(hitPoint.y);
	
	//--> pixelBorders.y = x.max; pixelBorders.v = y.max
	hitPoint = fmaxf(MC_bBoxMin, MC_bBoxMax);
	pixelBorders.y = ceil(hitPoint.x);
	pixelBorders.w = ceil(hitPoint.y);

	//clamp values
	pixelBorders.x = fminf(fmaxf(pixelBorders.x, 0), proj_x - 1);
	pixelBorders.y = fminf(fmaxf(pixelBorders.y, 0), proj_x - 1);
	pixelBorders.z = fminf(fmaxf(pixelBorders.z, 0), proj_y - 1);
	pixelBorders.w = fminf(fmaxf(pixelBorders.w, 0), proj_y - 1);
	


	
	voxelD[index2].x  = 0;
	voxelD[index2].y  = 0;
	voxelD[index2].z  = 0;
	voxelD[index2].w  = 0;
	distanceD[index2].x  = 0;
	distanceD[index2].y  = 0;
	distanceD[index2].z  = 0;
	distanceD[index2].w  = 0;

	//Loop over detected pixels and shoot rays back	again with manual unrolling
	for( pixel_y = pixelBorders.z + maxOverSampleInv*0.5f ; pixel_y < pixelBorders.w ; pixel_y+=maxOverSampleInv)
	{				
		for ( pixel_x = pixelBorders.x + maxOverSampleInv*0.5f ; pixel_x < pixelBorders.y ; pixel_x+=maxOverSampleInv)	
		{
			/*float pixel_xr = pixel_x + (curand_uniform(&state) - 0.5f) * maxOverSampleInv;
			float pixel_yr = pixel_y + (curand_uniform(&state) - 0.5f) * maxOverSampleInv;*/

			//if (pixel_x < 1) continue;
			float xAniso;
			float yAniso;

			MatrixVector3Mul(c_magAnisoInv, pixel_x, pixel_y, xAniso, yAniso);

			ray.x = c_detektor.x; 
			ray.y = c_detektor.y; 
			ray.z = c_detektor.z; 
			
			ray.x = ray.x + (pixel_x) * c_uPitch.x;
			ray.y = ray.y + (pixel_x) * c_uPitch.y;
			ray.z = ray.z + (pixel_x) * c_uPitch.z;
			
			ray.x = ray.x + (pixel_y) * c_vPitch.x;
			ray.y = ray.y + (pixel_y) * c_vPitch.y;
			ray.z = ray.z + (pixel_y) * c_vPitch.z;
			
			c_source.x = ray.x + 100000.0 * c_projNorm.x;
			c_source.y = ray.y + 100000.0 * c_projNorm.y;
			c_source.z = ray.z + 100000.0 * c_projNorm.z;
			ray.x = ray.x - c_source.x;
			ray.y = ray.y - c_source.y;
			ray.z = ray.z - c_source.z;

			// calculate ray direction
			ray = normalize(ray);
				
			//////////// BOX INTERSECTION (Voxel 1) /////////////////	
			tEntry.x = (c_bBoxMin.x + (x  ) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+1  ) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
				
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].x += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].x += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].x += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].x += (t_out-t_in);
				#endif
			}


			//////////// BOX INTERSECTION (Voxel 2) /////////////////	 
			tEntry.x = (c_bBoxMin.x + (x+1) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+2) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
				
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].y += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].y += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].y += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].y += (t_out-t_in);
				#endif
			}




			//////////// BOX INTERSECTION (Voxel 3) /////////////////	
			tEntry.x = (c_bBoxMin.x + (x+2) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+3) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
		
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].z += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].z += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].z += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].z += (t_out-t_in);
				#endif
			}


			//////////// BOX INTERSECTION (Voxel 4) /////////////////	 
			tEntry.x = (c_bBoxMin.x + (x+3) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+4) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
		
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].w += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].w += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].w += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].w += (t_out-t_in);
				#endif
			}// if hit voxel
		}//for loop y-pixel
	}//for loop x-pixel

//	float len = 0;
//	float3 lengths;
//	
//	lengths.x = 100;
//	if (x > c_volumeDim.x * 0.5f)
//	{
//		if (c_volumeDim.x - x < 100.0f)
//			lengths.x = c_volumeDim.x -x;
//	}
//	else
//	{
//		if (x < 100.0f)
//			lengths.x = x;
//	}
//	
//	
//	lengths.y = 100;
//	if (x > c_volumeDim.y * 0.5f)
//	{
//		if (c_volumeDim.y - y < 100.0f)
//			lengths.y = c_volumeDim.x -y;
//	}
//	else
//	{
//		if (y < 100.0f)
//			lengths.y = y;
//	}
//	
//	
//	lengths.z = 100;
//	if (x > c_volumeDim.z * 0.5f)
//	{
//		if (c_volumeDim.z - z < 100.0f)
//			lengths.z = c_volumeDim.x -z;
//	}
//	else
//	{
//		if (z < 100.0f)
//			lengths.z = z;
//	}
//
//	len = sqrtf(lengths.x * lengths.x + lengths.y * lengths.y + lengths.z * lengths.z);
//	if (len < 100)
//		len = 1.0f - expf(-(len * len));
//	else
//		len = 1.0f;

	//Only positive distance values are allowed
	distanceD[index2].x = fmaxf (0.f, distanceD[index2].x);
	distanceD[index2].y = fmaxf (0.f, distanceD[index2].y);
	distanceD[index2].z = fmaxf (0.f, distanceD[index2].z);
	distanceD[index2].w = fmaxf (0.f, distanceD[index2].w);	

	//Apply correction term to voxel
	if (distanceD[index2].x != 0.0f) voxelBlock.x += (lambda * voxelD[index2].x / (float)distanceD[index2].x);
	if (distanceD[index2].y != 0.0f) voxelBlock.y += (lambda * voxelD[index2].y / (float)distanceD[index2].y);
	if (distanceD[index2].z != 0.0f) voxelBlock.z += (lambda * voxelD[index2].z / (float)distanceD[index2].z);
	if (distanceD[index2].w != 0.0f) voxelBlock.w += (lambda * voxelD[index2].w / (float)distanceD[index2].w);


	//store values in global memory
	//__syncthreads();
	//vol2[voxelIndex] = temp2;
	
	#ifdef SM20
	surf3Dwrite(voxelBlock.x, surfref, x * 4 + 0, y, z);
	surf3Dwrite(voxelBlock.y, surfref, x * 4 + 4, y, z);
	surf3Dwrite(voxelBlock.z, surfref, x * 4 + 8, y, z);
	surf3Dwrite(voxelBlock.w, surfref, x * 4 + 12, y, z);
	#else
	vol2[voxelIndex] = voxelBlock;
	#endif
}


extern "C"
__global__ 
void backProjectionFP16(int proj_x, int proj_y, float lambda, int maxOverSample, float maxOverSampleInv, float* img, int stride, float distMin, float distMax)
{
	float3 ray;
	float3 borderMin;
	float3 borderMax;
	float3 hitPoint;
	float3 c_source;

	//curandState state;


	int4 pixelBorders; //--> x = x.min; y = x.max; z = y.min; v = y.max   	
	
	// index to access shared memory, e.g. thread linear address in a block
	const unsigned int index2 = (threadIdx.z * blockDim.x * blockDim.y) + (threadIdx.y * blockDim.x) + threadIdx.x;	

	unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	const unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
	const unsigned int z = blockIdx.z * blockDim.z + threadIdx.z;

	if (x >= c_volumeDim_x_quarter || y >= c_volumeDim.y || z >= c_volumeDim.z) return;

	//summed up distance per voxel in voxelBlock in shared memory
	volatile float4* distanceD = (float4*)(sBuffer);
	
	//Correction term per voxel in shared memory
	volatile float4* voxelD = distanceD + blockDim.x * blockDim.y * blockDim.z;
	//volatile float4* voxelD = (float4*)(sBuffer);
	
	
	float4 voxelBlock;

	//float3 detectorNormal;
	float3 MC_bBoxMin;
	float3 MC_bBoxMax;
	float t;
	
	float t_in, t_out;
	float3 tEntry;
	float3 tExit;
	float3 tmin, tmax;
	float pixel_y, pixel_x;	

	unsigned short tempfp16;

	#ifdef SM20
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 0, y, z);
	voxelBlock.x = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 2, y, z);
	voxelBlock.y = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 4, y, z);
	voxelBlock.z = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 6, y, z);
	voxelBlock.w = __half2float(tempfp16);
	#else
	voxelBlock = vol2[voxelIndex];
	#endif


	//adopt x coordinate to single voxels, not voxelBlocks
	x = x * 4;

	//MacroCell bounding box:
	MC_bBoxMin.x = c_bBoxMin.x + (x) * c_voxelSize.x;
	MC_bBoxMin.y = c_bBoxMin.y + (y) * c_voxelSize.y;
	MC_bBoxMin.z = c_bBoxMin.z + (z) * c_voxelSize.z;
	MC_bBoxMax.x = c_bBoxMin.x + ( x + 5) * c_voxelSize.x;
	MC_bBoxMax.y = c_bBoxMin.y + ( y + 1) * c_voxelSize.y;
	MC_bBoxMax.z = c_bBoxMin.z + ( z + 1) * c_voxelSize.z;

	
	//find maximal projection on detector:
	borderMin = make_float3(FLT_MAX, FLT_MAX, FLT_MAX);
	borderMax = make_float3(-200000.f, -200000.f, -200000.f);


	//The loop has been manually unrolled: nvcc cannot handle inner loops
	//first corner
	//ray.x = -c_projNorm.x;
	//ray.y = -c_projNorm.y;
	//ray.z = -c_projNorm.z;

	//ray = normalize(ray);
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);

	if (!(t >= distMin && t < distMax)) return;

	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//second corner
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//third corner
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//fourth corner
	t = (c_projNorm.x * MC_bBoxMin.x + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + MC_bBoxMin.x;
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//fifth corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//sixth corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * MC_bBoxMin.y + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + MC_bBoxMin.y;
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//seventh corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * MC_bBoxMin.z);
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + MC_bBoxMin.z;

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//eighth corner
	t = (c_projNorm.x * (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x)) + c_projNorm.y * (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y)) + c_projNorm.z * (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z)));
	t += (-c_projNorm.x * c_detektor.x - c_projNorm.y * c_detektor.y - c_projNorm.z * c_detektor.z);
	t = abs(t);
	hitPoint.x = t * (-c_projNorm.x) + (MC_bBoxMin.x + (MC_bBoxMax.x - MC_bBoxMin.x));
	hitPoint.y = t * (-c_projNorm.y) + (MC_bBoxMin.y + (MC_bBoxMax.y - MC_bBoxMin.y));
	hitPoint.z = t * (-c_projNorm.z) + (MC_bBoxMin.z + (MC_bBoxMax.z - MC_bBoxMin.z));

	borderMin = fminf(hitPoint, borderMin);
	borderMax = fmaxf(hitPoint, borderMax);

	//get largest area
	MC_bBoxMin = fminf(borderMin, borderMax);
	MC_bBoxMax = fmaxf(borderMin, borderMax);

	//swap x values if opposite projection direction
//	if (c_projNorm.y * c_projNorm.z >= 0)
	{
//		float ttemp = MC_bBoxMin.x;
//		MC_bBoxMin.x = MC_bBoxMax.x;
//		MC_bBoxMax.x = ttemp;
	}
//	else
	if (c_projNorm.x <= 0)
	{
		float temp = MC_bBoxMin.x;
		MC_bBoxMin.x = MC_bBoxMax.x;
		MC_bBoxMax.x = temp;
		//temp = MC_bBoxMin.y;
		//MC_bBoxMin.y = MC_bBoxMax.y;
		//MC_bBoxMax.y = temp;
	}
	//if (c_projNorm.x * c_projNorm.y >= 0) 
	//{
	//	float temp = MC_bBoxMin.y;
	//	MC_bBoxMin.y = MC_bBoxMax.y;
	//	MC_bBoxMax.y = temp;

	//	
	//}
	//else
	//{
	//	float ttemp = MC_bBoxMin.x;
	//	MC_bBoxMin.x = MC_bBoxMax.x;
	//	MC_bBoxMax.x = ttemp;
	//}

	//Convert global coordinated to projection pixel indices
	MatrixVector3Mul(c_DetectorMatrix, &MC_bBoxMin);    
	MatrixVector3Mul(c_DetectorMatrix, &MC_bBoxMax);

	hitPoint = fminf(MC_bBoxMin, MC_bBoxMax);
	//--> pixelBorders.x = x.min; pixelBorders.z = y.min;
	pixelBorders.x = floor(hitPoint.x); 
	pixelBorders.z = floor(hitPoint.y);
	
	//--> pixelBorders.y = x.max; pixelBorders.v = y.max
	hitPoint = fmaxf(MC_bBoxMin, MC_bBoxMax);
	pixelBorders.y = ceil(hitPoint.x);
	pixelBorders.w = ceil(hitPoint.y);

	//clamp values
	pixelBorders.x = fminf(fmaxf(pixelBorders.x, 0), proj_x - 1);
	pixelBorders.y = fminf(fmaxf(pixelBorders.y, 0), proj_x - 1);
	pixelBorders.z = fminf(fmaxf(pixelBorders.z, 0), proj_y - 1);
	pixelBorders.w = fminf(fmaxf(pixelBorders.w, 0), proj_y - 1);
	


	
	voxelD[index2].x  = 0;
	voxelD[index2].y  = 0;
	voxelD[index2].z  = 0;
	voxelD[index2].w  = 0;
	distanceD[index2].x  = 0;
	distanceD[index2].y  = 0;
	distanceD[index2].z  = 0;
	distanceD[index2].w  = 0;

	//Loop over detected pixels and shoot rays back	again with manual unrolling
	for( pixel_y = pixelBorders.z + maxOverSampleInv*0.5f ; pixel_y < pixelBorders.w ; pixel_y+=maxOverSampleInv)
	{				
		for ( pixel_x = pixelBorders.x + maxOverSampleInv*0.5f ; pixel_x < pixelBorders.y ; pixel_x+=maxOverSampleInv)	
		{
			/*float pixel_xr = pixel_x + (curand_uniform(&state) - 0.5f) * maxOverSampleInv;
			float pixel_yr = pixel_y + (curand_uniform(&state) - 0.5f) * maxOverSampleInv;*/

			float xAniso;
			float yAniso;

			MatrixVector3Mul(c_magAnisoInv, pixel_x, pixel_y, xAniso, yAniso);

			//if (pixel_x < 1) continue;
			ray.x = c_detektor.x; 
			ray.y = c_detektor.y; 
			ray.z = c_detektor.z; 
			
			ray.x = ray.x + (pixel_x) * c_uPitch.x;
			ray.y = ray.y + (pixel_x) * c_uPitch.y;
			ray.z = ray.z + (pixel_x) * c_uPitch.z;
			
			ray.x = ray.x + (pixel_y) * c_vPitch.x;
			ray.y = ray.y + (pixel_y) * c_vPitch.y;
			ray.z = ray.z + (pixel_y) * c_vPitch.z;
			
			c_source.x = ray.x + 100000.0 * c_projNorm.x;
			c_source.y = ray.y + 100000.0 * c_projNorm.y;
			c_source.z = ray.z + 100000.0 * c_projNorm.z;
			ray.x = ray.x - c_source.x;
			ray.y = ray.y - c_source.y;
			ray.z = ray.z - c_source.z;

			// calculate ray direction
			ray = normalize(ray);
				
			//////////// BOX INTERSECTION (Voxel 1) /////////////////	
			tEntry.x = (c_bBoxMin.x + (x  ) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+1  ) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
				
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].x += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].x += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].x += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].x += (t_out-t_in);
				#endif
			}


			//////////// BOX INTERSECTION (Voxel 2) /////////////////	 
			tEntry.x = (c_bBoxMin.x + (x+1) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+2) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
				
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].y += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].y += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].y += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].y += (t_out-t_in);
				#endif
			}




			//////////// BOX INTERSECTION (Voxel 3) /////////////////	
			tEntry.x = (c_bBoxMin.x + (x+2) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+3) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
		
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].z += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].z += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].z += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].z += (t_out-t_in);
				#endif
			}


			//////////// BOX INTERSECTION (Voxel 4) /////////////////	 
			tEntry.x = (c_bBoxMin.x + (x+3) * c_voxelSize.x);
			tEntry.y = (c_bBoxMin.y + (y  ) * c_voxelSize.y);
			tEntry.z = (c_bBoxMin.z + (z  ) * c_voxelSize.z);
			tEntry.x = (tEntry.x - c_source.x) / ray.x;
			tEntry.y = (tEntry.y - c_source.y) / ray.y;
			tEntry.z = (tEntry.z - c_source.z) / ray.z;

			tExit.x = (c_bBoxMin.x + (x+4) * c_voxelSize.x);
			tExit.y = (c_bBoxMin.y + (y+1  ) * c_voxelSize.y);
			tExit.z = (c_bBoxMin.z + (z+1  ) * c_voxelSize.z);

			tExit.x = ((tExit.x) - c_source.x) / ray.x;
			tExit.y = ((tExit.y) - c_source.y) / ray.y;
			tExit.z = ((tExit.z) - c_source.z) / ray.z;

			tmin = fminf(tEntry, tExit);
			tmax = fmaxf(tEntry, tExit);
			
			t_in = fmaxf(fmaxf(tmin.x, tmin.y), tmin.z);
			t_out = fminf(fminf(tmax.x, tmax.y), tmax.z);
			////////////////////////////////////////////////////////////////
		
			// if the ray hits the voxel
			if((t_out - t_in) > 0.0f )
			{
				#ifdef CONST_LENGTH_MODE
				voxelD[index2].w += (tex2D(tex, xAniso, yAniso)) * (c_voxelSize.x);
				distanceD[index2].w += (c_voxelSize.x);
				#endif
				#ifdef PRECISE_LENGTH_MODE
				voxelD[index2].w += (tex2D(tex, xAniso, yAniso)) * (t_out-t_in);
				distanceD[index2].w += (t_out-t_in);
				#endif
			}// if hit voxel
		}//for loop y-pixel
	}//for loop x-pixel

//	float len = 0;
//	float3 lengths;
//	
//	lengths.x = 100;
//	if (x > c_volumeDim.x * 0.5f)
//	{
//		if (c_volumeDim.x - x < 100.0f)
//			lengths.x = c_volumeDim.x -x;
//	}
//	else
//	{
//		if (x < 100.0f)
//			lengths.x = x;
//	}
//	
//	
//	lengths.y = 100;
//	if (x > c_volumeDim.y * 0.5f)
//	{
//		if (c_volumeDim.y - y < 100.0f)
//			lengths.y = c_volumeDim.x -y;
//	}
//	else
//	{
//		if (y < 100.0f)
//			lengths.y = y;
//	}
//	
//	
//	lengths.z = 100;
//	if (x > c_volumeDim.z * 0.5f)
//	{
//		if (c_volumeDim.z - z < 100.0f)
//			lengths.z = c_volumeDim.x -z;
//	}
//	else
//	{
//		if (z < 100.0f)
//			lengths.z = z;
//	}
//
//	len = sqrtf(lengths.x * lengths.x + lengths.y * lengths.y + lengths.z * lengths.z);
//	if (len < 100)
//		len = 1.0f - expf(-(len * len));
//	else
//		len = 1.0f;

	//Only positive distance values are allowed
	distanceD[index2].x = fmaxf (0.f, distanceD[index2].x);
	distanceD[index2].y = fmaxf (0.f, distanceD[index2].y);
	distanceD[index2].z = fmaxf (0.f, distanceD[index2].z);
	distanceD[index2].w = fmaxf (0.f, distanceD[index2].w);	

	//Apply correction term to voxel
	if (distanceD[index2].x != 0.0f) voxelBlock.x += (lambda * voxelD[index2].x / (float)distanceD[index2].x);
	if (distanceD[index2].y != 0.0f) voxelBlock.y += (lambda * voxelD[index2].y / (float)distanceD[index2].y);
	if (distanceD[index2].z != 0.0f) voxelBlock.z += (lambda * voxelD[index2].z / (float)distanceD[index2].z);
	if (distanceD[index2].w != 0.0f) voxelBlock.w += (lambda * voxelD[index2].w / (float)distanceD[index2].w);


	//store values in global memory
	//__syncthreads();
	//vol2[voxelIndex] = temp2;
	
	#ifdef SM20
	tempfp16 = __float2half_rn(voxelBlock.x);
	surf3Dwrite(tempfp16, surfref, x * 2 + 0, y, z);
	tempfp16 = __float2half_rn(voxelBlock.y);
	surf3Dwrite(tempfp16, surfref, x * 2 + 2, y, z);
	tempfp16 = __float2half_rn(voxelBlock.z);
	surf3Dwrite(tempfp16, surfref, x * 2 + 4, y, z);
	tempfp16 = __float2half_rn(voxelBlock.w);
	surf3Dwrite(tempfp16, surfref, x * 2 + 6, y, z);
	#else
	vol2[voxelIndex] = voxelBlock;
	#endif
}


extern "C"
__global__ 
void convertVolumeFP16ToFP32(float* volPlane, int stride, unsigned int z)
{
	unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	const unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;

	if (x >= c_volumeDim_x_quarter || y >= c_volumeDim.y || z >= c_volumeDim.z) return;

	float4 voxelBlock;

	unsigned short tempfp16;

	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 0, y, z);
	voxelBlock.x = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 2, y, z);
	voxelBlock.y = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 4, y, z);
	voxelBlock.z = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 6, y, z);
	voxelBlock.w = __half2float(tempfp16);
	
	//adopt x coordinate to single voxels, not voxelBlocks
	x = x * 4;
	
	volPlane[y * stride + x + 0] = -voxelBlock.x;
	volPlane[y * stride + x + 1] = -voxelBlock.y;
	volPlane[y * stride + x + 2] = -voxelBlock.z;
	volPlane[y * stride + x + 3] = -voxelBlock.w;
}

extern "C"
__global__
void convertVolume3DFP16ToFP32(float* volPlane, int stride)
{
	unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	const unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
	const unsigned int z = blockIdx.z * blockDim.z + threadIdx.z;

	if (x >= c_volumeDim_x_quarter || y >= c_volumeDim.y || z >= c_volumeDim.z) return;

	float4 voxelBlock;

	unsigned short tempfp16;

	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 0, y, z);
	voxelBlock.x = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 2, y, z);
	voxelBlock.y = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 4, y, z);
	voxelBlock.z = __half2float(tempfp16);
	surf3Dread(&tempfp16, surfref, x * 2 * 4 + 6, y, z);
	voxelBlock.w = __half2float(tempfp16);

	//adopt x coordinate to single voxels, not voxelBlocks
	x = x * 4;

	volPlane[y * stride + x + 0] = -voxelBlock.x;
	volPlane[y * stride + x + 1] = -voxelBlock.y;
	volPlane[y * stride + x + 2] = -voxelBlock.z;
	volPlane[y * stride + x + 3] = -voxelBlock.w;
}

#endif //BACKPROJECTIONSQUAREOS_CU
