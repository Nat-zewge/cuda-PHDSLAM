/*
 * main.cpp
 *
 *  Created on: Mar 24, 2011
 *      Author: cheesinglee
 */

#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <algorithm>
#include <sstream>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <string>
#include "slamtypes.h"
#include "slamparams.h"
#include "cutil.h"
#include <assert.h>
#include <float.h>
//#include "cuPrintf.cu"
#include "matrix.h"
#include "mat.h"

//#include "ConstantVelocity2DKinematicModel.cu"

// include gcc-compiled boost rng
#include "rng.h"

#ifdef __CDT_PARSER__
#define __device__
#define __global__
#define __constant__
#define __shared__
#define __host__
#endif

#define DEBUG

#ifdef DEBUG
#define DEBUG_MSG(x) cout <<"["<< __func__ << "]: " << x << endl
#define DEBUG_VAL(x) cout << "["<<__func__ << "]: " << #x << " = " << x << endl ;
#else
#define DEBUG_MSG(x)
#define DEBUG_VAL(x)
#endif

//--- Make kernel helper functions externally visible
extern "C"
void
phdPredict( ParticleSLAM& particles ) ;

extern "C"
void
phdPredictVp( ParticleSLAM& particles ) ;

extern "C"
void
addBirths( ParticleSLAM& particles, measurementSet ZPrev ) ;

extern "C"
ParticleSLAM
phdUpdate(ParticleSLAM& particles, measurementSet measurements) ;

extern "C"
ParticleSLAM resampleParticles( ParticleSLAM oldParticles, int nParticles=-1 ) ;

extern "C"
void recoverSlamState(ParticleSLAM particles, ConstantVelocityState& expectedPose,
		gaussianMixture& expectedMap) ;

extern "C"
void setDeviceConfig( const SlamConfig& config ) ;
//--- End external function declaration

// SLAM configuration, externally declared
extern SlamConfig config ;

// device memory limit, externally declared
extern size_t deviceMemLimit ;

const char * filename = "data/measurements2.txt" ;
bool breakUpdate = false ;

using namespace std ;


// Constant memory variables
__constant__ RangeBearingMeasurement Z[MAXMEASUREMENTS] ;
__constant__ SlamConfig dev_config ;

// other global device variables
__device__ REAL* dev_C ;
__device__ REAL* dev_factorial ;
//__device__ REAL* dev_qspower ;
//__device__ REAL* dev_pspower ;
__device__ REAL* dev_qdpower ;
__device__ REAL* dev_pdpower ;
__device__ REAL* dev_cardinality_clutter ;

//ConstantVelocityModelProps modelProps  = {STDX, STDY,STDTHETA} ;
//ConstantVelocity2DKinematicModel motionModel(modelProps) ;

__device__ void
sumByReduction( volatile REAL* sdata, REAL mySum, const unsigned int tid )
{
    sdata[tid] = mySum;
    __syncthreads();

    // do reduction in shared mem
	if (tid < 128) { sdata[tid] = mySum = mySum + sdata[tid + 128]; } __syncthreads();
	if (tid <  64) { sdata[tid] = mySum = mySum + sdata[tid +  64]; } __syncthreads();

    if (tid < 32)
    {
        sdata[tid] = mySum = mySum + sdata[tid + 32];
        sdata[tid] = mySum = mySum + sdata[tid + 16];
        sdata[tid] = mySum = mySum + sdata[tid +  8];
        sdata[tid] = mySum = mySum + sdata[tid +  4];
        sdata[tid] = mySum = mySum + sdata[tid +  2];
        sdata[tid] = mySum = mySum + sdata[tid +  1];
    }
    __syncthreads() ;
}

__device__ void
productByReduction( volatile REAL* sdata, REAL mySum, const unsigned int tid )
{
    sdata[tid] = mySum;
    __syncthreads();

    // do reduction in shared mem
	if (tid < 128) { sdata[tid] = mySum = mySum * sdata[tid + 128]; } __syncthreads();
	if (tid <  64) { sdata[tid] = mySum = mySum * sdata[tid +  64]; } __syncthreads();

    if (tid < 32)
    {
        sdata[tid] = mySum = mySum * sdata[tid + 32];
        sdata[tid] = mySum = mySum * sdata[tid + 16];
        sdata[tid] = mySum = mySum * sdata[tid +  8];
        sdata[tid] = mySum = mySum * sdata[tid +  4];
        sdata[tid] = mySum = mySum * sdata[tid +  2];
        sdata[tid] = mySum = mySum * sdata[tid +  1];
    }
    __syncthreads() ;
}

__device__ void
maxByReduction( volatile REAL* sdata, REAL val, const unsigned int tid )
{
	sdata[tid] = val ;
	__syncthreads();

	// do reduction in shared mem
	if (tid < 128) { sdata[tid] = val = (sdata[tid+128] > val) ? sdata[tid+128] : val ; } __syncthreads();
	if (tid <  64) { sdata[tid] = val = (sdata[tid+64] > val) ? sdata[tid+64] : val ; } __syncthreads();

	if (tid < 32)
	{
		sdata[tid] = val = (sdata[tid+32] > val) ? sdata[tid+32] : val ;
		sdata[tid] = val = (sdata[tid+16] > val) ? sdata[tid+16] : val ;
		sdata[tid] = val = (sdata[tid+8] > val) ? sdata[tid+8] : val ;
		sdata[tid] = val = (sdata[tid+4] > val) ? sdata[tid+4] : val ;
		sdata[tid] = val = (sdata[tid+2] > val) ? sdata[tid+2] : val ;
		sdata[tid] = val = (sdata[tid+1] > val) ? sdata[tid+1] : val ;
	}
	__syncthreads() ;
}

__device__ void
computeEsf( volatile REAL* sdata, REAL val, const unsigned int tid, int n )
{
	sdata[tid] = val ;
	__syncthreads();

	for ( int j = 0 ; j < n ; j++ )
	{
		if ( tid < (j+1) )
			sdata[tid] = sdata
	}
}

__device__ void
makePositiveDefinite( REAL A[4] )
{
	// eigenvalues:
	REAL detA = A[0]*A[3] + A[1]*A[2] ;
	// check if already positive definite
	if ( detA > 0 && A[0] > 0 )
	{
		A[1] = (A[1] + A[2])/2 ;
		A[2] = A[1] ;
		return ;
	}
	REAL trA = A[0] + A[3] ;
	REAL trA2 = trA*trA ;
	REAL eval1 = 0.5*trA + 0.5*sqrt( trA2 - 4*detA ) ;
	REAL eval2 = 0.5*trA - 0.5*sqrt( trA2 - 4*detA ) ;

	// eigenvectors:
	REAL Q[4] ;
	if ( fabs(A[1]) > 0 )
	{
		Q[0] = eval1 - A[3] ;
		Q[1] = A[1] ;
		Q[2] = eval2 - A[3] ;
		Q[3] = A[1] ;
	}
	else if ( fabs(A[2]) > 0 )
	{
		Q[0] = A[2] ;
		Q[1] = eval1 - A[0] ;
		Q[2] = A[2] ;
		Q[3] = eval2 - A[0] ;
	}
	else
	{
		Q[0] = 1 ;
		Q[1] = 0 ;
		Q[2] = 0 ;
		Q[3] = 1 ;
	}

	// make eigenvalues positive
	if ( eval1 < 0 )
		eval1 = DBL_EPSILON ;
	if ( eval2 < 0 )
		eval2 = DBL_EPSILON ;

	// compute the approximate matrix
	A[0] = Q[0]*Q[0]*eval1 + Q[2]*Q[2]*eval2 ;
	A[1] = Q[0]*eval1*Q[1] + Q[2]*eval2*Q[3] ;
	A[2] = A[1] ;
	A[3] = Q[1]*Q[1]*eval1 + Q[3]*Q[3]*eval2 ;
}

__device__ REAL
computeMahalDist(Gaussian2D a, Gaussian2D b)
{
	REAL innov[2] ;
	REAL sigma[4] ;
	REAL detSigma ;
	REAL sigmaInv[4] = {1,0,0,1} ;
	innov[0] = a.mean[0] - b.mean[0] ;
	innov[1] = a.mean[1] - b.mean[1] ;
	sigma[0] = a.cov[0] + b.cov[0] ;
	sigma[1] = a.cov[1] + b.cov[1] ;
	sigma[2] = a.cov[2] + b.cov[2] ;
	sigma[3] = a.cov[3] + b.cov[3] ;
	detSigma = sigma[0]*sigma[3] - sigma[1]*sigma[2] ;
//	detSigma = a.cov[0]*a.cov[3] - a.cov[1]*a.cov[2] ;
	if (detSigma > FLT_MIN)
	{
//		sigmaInv[0] = a.cov[3]/detSigma ;
//		sigmaInv[1] = -a.cov[1]/detSigma ;
//		sigmaInv[2] = -a.cov[2]/detSigma ;
//		sigmaInv[3] = a.cov[0]/detSigma ;
		sigmaInv[0] = sigma[3]/detSigma ;
		sigmaInv[1] = -sigma[1]/detSigma ;
		sigmaInv[2] = -sigma[2]/detSigma ;
		sigmaInv[3] = sigma[0]/detSigma ;
	}
	return  innov[0]*innov[0]*sigmaInv[0] +
			innov[0]*innov[1]*(sigmaInv[1]+sigmaInv[2]) +
			innov[1]*innov[1]*sigmaInv[3] ;
}

__device__ REAL
computeHellingerDist( Gaussian2D a, Gaussian2D b)
{
	REAL innov[2] ;
	REAL sigma[4] ;
	REAL detSigma ;
	REAL sigmaInv[4] = {1,0,0,1} ;
	REAL dist ;
	innov[0] = a.mean[0] - b.mean[0] ;
	innov[1] = a.mean[1] - b.mean[1] ;
	sigma[0] = a.cov[0] + b.cov[0] ;
	sigma[1] = a.cov[1] + b.cov[1] ;
	sigma[2] = a.cov[2] + b.cov[2] ;
	sigma[3] = a.cov[3] + b.cov[3] ;
	detSigma = sigma[0]*sigma[3] - sigma[1]*sigma[2] ;
	if (detSigma > FLT_MIN)
	{
		sigmaInv[0] = sigma[3]/detSigma ;
		sigmaInv[1] = -sigma[1]/detSigma ;
		sigmaInv[2] = -sigma[2]/detSigma ;
		sigmaInv[3] = sigma[0]/detSigma ;
	}
	REAL epsilon = -0.25*
			(innov[0]*innov[0]*sigmaInv[0] +
			 innov[0]*innov[1]*(sigmaInv[1]+sigmaInv[2]) +
			 innov[1]*innov[1]*sigmaInv[3]) ;

	// determinant of half the sum of covariances
	detSigma /= 4 ;
	dist = 1/detSigma ;

	// product of covariances
	sigma[0] = a.cov[0]*b.cov[0] + a.cov[2]*b.cov[1] ;
	sigma[1] = a.cov[1]*b.cov[0] + a.cov[3]*b.cov[1] ;
	sigma[2] = a.cov[0]*b.cov[2] + a.cov[2]*b.cov[3] ;
	sigma[3] = a.cov[1]*b.cov[2] + a.cov[3]*b.cov[3] ;
	detSigma = sigma[0]*sigma[3] - sigma[1]*sigma[2] ;
	dist *= sqrt(detSigma) ;
	dist = 1 - sqrt(dist)*exp(epsilon) ;
	return dist ;
}

double logSumExp( vector<double>log_terms )
{
	double val = log_terms[0] ;
	double sum = 0 ;
	for ( int i = 0 ; i < log_terms.size() ; i++ )
	{
		if ( log_terms[i] > val )
			val = log_terms[i] ;
	}
	for ( int i = 0 ; i < log_terms.size() ; i++ )
	{
		sum += exp(log_terms[i]-val) ;
	}
	sum = log(sum) + val ;
	return sum ;
}

int nextPowerOfTwo(int a)
{
	int n = a - 1 ;
	n = n | (n >> 1) ;
	n = n | (n >> 2) ;
	n = n | (n >> 4) ;
	n = n | (n >> 8);
	n = n | (n >> 16) ;
	n = n + 1 ;
	return n ;
}
__device__ REAL wrapAngle(REAL a)
{
	REAL remainder = fmod(a, float(2*M_PI)) ;
	if ( remainder > M_PI )
		remainder -= 2*M_PI ;
	else if ( remainder < -M_PI )
		remainder += 2*M_PI ;
	return remainder ;
}

__global__ void
cphdConstantsKernel( )
{
	int n = threadIdx.x ;
	int k = blockIdx.x ;
	int stride = dev_config.maxCardinality + 1 ;
	int idx = k*stride + n ;
	int log_nchoosek = 0 ;
	extern __shared__ REAL sdata[] ;

	// compute the (log) binomial coefficients
	if ( k == 0 )
	{
		log_nchoosek = 0 ;
	}
	else if ( n == 0 )
	{
		log_nchoosek = -INFINITY ;
	}
	else
	{
		for ( int i = 1 ; i <= k ; i++ )
		{
			log_nchoosek += log( n-(k-i) ) - log(i) ;
		}
	}
	dev_C[idx] = log_nchoosek ;

	// compute (log) factorials
	REAL val = log(n) ;
	sumByReduction( sdata, val, n ) ;
	__syncthreads() ;
	if ( n == 0 )
		dev_factorial[n] = sdata[0] ;

	// compute (log) powers of pd,qd
	if ( n == 0 )
	{
		dev_pdpower = k*log( dev_config.pd ) ;
		dev_qdpower = k*log( 1-dev_config.pd ) ;
	}

}

void
initCphdConstants()
{
	CUDA_SAFE_CALL(
				cudaMalloc( (void**)&dev_C,
							pow(config.maxCardinality+1,2)*sizeof(REAL) ) ) ;
	CUDA_SAFE_CALL(
				cudaMalloc( (void**)&dev_factorial,
							(config.maxCardinality+1)*sizeof(REAL) ) ) ;
	CUDA_SAFE_CALL(
				cudaMalloc( (void**)&dev_pdpower,
							(config.maxCardinality+1)*sizeof(REAL) ) ) ;
	CUDA_SAFE_CALL(
				cudaMalloc( (void**)&dev_qdpower,
							(config.maxCardinality+1)*sizeof(REAL) ) ) ;
//	CUDA_SAFE_CALL(
//				cudaMalloc( (void**)&dev_pspower,
//							(config.maxCardinality+1)*sizeof(REAL) ) ) ;
//	CUDA_SAFE_CALL(
//				cudaMalloc( (void**)&dev_qspower,
//							(config.maxCardinality+1)*sizeof(REAL) ) ) ;

	int n_blocks = config.maxCardinality+1 ;
	int n_threads = nBlocks ;
	cphdConstantsKernel<<<n_blocks, n_threads, n_threads*sizeof(REAL)>>>() ;
	CUDA_SAFE_THREAD_SYNC() ;
}

__global__ void
phdPredictKernelVp(AckermanState* particles_prior,
                   AckermanControl control,
				   AckermanNoise* noise,
				   AckermanState* particles_predict)
{
    const int tid = threadIdx.x ;
	const int predict_idx = blockIdx.x*blockDim.x + tid ;
	const int prior_idx = predict_idx/dev_config.nPredictParticles ;
	AckermanState oldState = particles_prior[prior_idx] ;
    AckermanState newState ;
    REAL vc = control.v_encoder/(1-tan(control.alpha)*dev_config.h/dev_config.l) ;
    REAL xc_dot = vc*cos(oldState.ptheta) ;
    REAL yc_dot = vc*sin(oldState.ptheta) ;
    REAL thetac_dot = vc*tan(control.alpha)/dev_config.l ;
    newState.px = oldState.px +
            dev_config.dt*(xc_dot -
            thetac_dot*( dev_config.a*sin(oldState.ptheta) + dev_config.b*cos(oldState.ptheta) )
    ) ;
    newState.py = oldState.py +
            dev_config.dt*(yc_dot -
            thetac_dot*( dev_config.a*cos(oldState.ptheta) - dev_config.b*sin(oldState.ptheta) )
    ) ;
    newState.ptheta = wrapAngle(oldState.ptheta + dev_config.dt*thetac_dot) ;
	particles_predict[predict_idx] = newState ;
}

void
phdPredictVp(ParticleSLAM& particles, AckermanControl control )
{
    // generate random noise values
    int nParticles = particles.nParticles ;
    std::vector<AckermanNoise> noiseVector(nParticles) ;
//    boost::normal_distribution<double> normal_dist ;
//    boost::variate_generator< boost::taus88, boost::normal_distribution<double> > var_gen( rng_g, normal_dist ) ;
    for (unsigned int i = 0 ; i < nParticles ; i++ )
    {
        noiseVector[i].n_alpha = config.std_alpha * randn() ;
        noiseVector[i].n_encoder = config.std_encoder * randn() ;
    }

    // copy to device memory
    cudaEvent_t start, stop ;
    cudaEventCreate( &start ) ;
    cudaEventCreate( &stop ) ;
    cudaEventRecord( start,0 ) ;
    AckermanState* dev_states ;
    AckermanNoise* dev_noise ;

    CUDA_SAFE_CALL(
        cudaMalloc((void**)&dev_states, nParticles*sizeof(AckermanState) )
    ) ;
    CUDA_SAFE_CALL(
        cudaMalloc((void**)&dev_noise, nParticles*sizeof(AckermanNoise) )
    ) ;
    CUDA_SAFE_CALL(
        cudaMemcpy(dev_states, &particles.states[0],
        nParticles*sizeof(ConstantVelocityState),cudaMemcpyHostToDevice)
    ) ;
    CUDA_SAFE_CALL(
        cudaMemcpy(dev_noise, &noiseVector[0],
        nParticles*sizeof(ConstantVelocityNoise), cudaMemcpyHostToDevice)
    ) ;

    // launch the kernel
    int nThreads = min(nParticles,512) ;
    int nBlocks = (nParticles+511)/512 ;
    phdPredictKernelVp
    <<<nBlocks, nThreads>>>
	(dev_states,control,dev_noise,dev_states) ;

    // copy results from device
    CUDA_SAFE_CALL(
        cudaMemcpy(&particles.states[0], dev_states,
        nParticles*sizeof(ConstantVelocityState),cudaMemcpyDeviceToHost)
    ) ;

    // log time
    cudaEventRecord( stop,0 ) ;
    cudaEventSynchronize( stop ) ;
    float elapsed ;
    cudaEventElapsedTime( &elapsed, start, stop ) ;
    fstream predictTimeFile( "predicttime.log", fstream::out|fstream::app ) ;
    predictTimeFile << elapsed << endl ;
    predictTimeFile.close() ;

    // clean up
    cudaFree( dev_states ) ;
    cudaFree( dev_noise ) ;
}

__global__ void
phdPredictKernel(ConstantVelocityState* particles_prior,
		ConstantVelocityNoise* noise, ConstantVelocityState* particles_predict )
{
	const int tid = threadIdx.x ;
	const int predictIdx = blockIdx.x*blockDim.x + tid ;
	const int priorIdx = predictIdx/dev_config.nPredictParticles ;
	ConstantVelocityState oldState = particles_prior[priorIdx] ;
	ConstantVelocityState newState ;
//	typename modelType::stateType newState = mm(particles[particleIdx],*control,noise[particleIdx]) ;
	newState.px = oldState.px +
			dev_config.dt*(oldState.vx*cos(oldState.ptheta) -
						   oldState.vy*sin(oldState.ptheta))+
			dev_config.dt*dev_config.dt*0.5*(noise[predictIdx].ax*cos(oldState.ptheta) -
											 noise[predictIdx].ay*sin(oldState.ptheta)) ;
	newState.py = oldState.py +
			dev_config.dt*(oldState.vx*sin(oldState.ptheta) +
						   oldState.vy*cos(oldState.ptheta)) +
			dev_config.dt*dev_config.dt*0.5*(noise[predictIdx].ax*sin(oldState.ptheta) +
											 noise[predictIdx].ay*cos(oldState.ptheta)) ;
	newState.ptheta = wrapAngle(oldState.ptheta +
								dev_config.dt*oldState.vtheta +
								0.5*dev_config.dt*dev_config.dt*noise[predictIdx].atheta) ;
	newState.vx = oldState.vx + dev_config.dt*noise[predictIdx].ax ;
	newState.vy = oldState.vy + dev_config.dt*noise[predictIdx].ay ;
	newState.vtheta = oldState.vtheta + dev_config.dt*noise[predictIdx].atheta ;
	particles_predict[predictIdx] = newState ;
}

void
phdPredict(ParticleSLAM& particles)
{
	// generate random noise values
	int nParticles = particles.nParticles ;
	int nPredict = nParticles*config.nPredictParticles ;
	std::vector<ConstantVelocityNoise> noiseVector(nPredict) ;
	for (unsigned int i = 0 ; i < nPredict ; i++ )
	{
		noiseVector[i].ax = 3*config.ax * randn() ;
		noiseVector[i].ay = 3*config.ay * randn() ;
		noiseVector[i].atheta = 3*config.atheta * randn() ;
	}

	// copy to device memory
	cudaEvent_t start, stop ;
	cudaEventCreate( &start ) ;
	cudaEventCreate( &stop ) ;
	cudaEventRecord( start,0 ) ;

	// allocate device memory
	ConstantVelocityState* dev_states_prior = NULL ;
	ConstantVelocityState* dev_states_predict = NULL ;
	ConstantVelocityNoise* dev_noise = NULL ;
	CUDA_SAFE_CALL(
				cudaMalloc((void**)&dev_states_prior,
						   nParticles*sizeof(ConstantVelocityState) ) ) ;
	CUDA_SAFE_CALL(
				cudaMalloc((void**)&dev_states_predict,
						   nPredict*sizeof(ConstantVelocityState) ) ) ;
	CUDA_SAFE_CALL(
				cudaMalloc((void**)&dev_noise,
						   nParticles*sizeof(ConstantVelocityNoise) ) ) ;

	// copy inputs
	CUDA_SAFE_CALL(
				cudaMemcpy(dev_states_prior, &particles.states[0],
						   nParticles*sizeof(ConstantVelocityState),
							cudaMemcpyHostToDevice) ) ;
	CUDA_SAFE_CALL(
				cudaMemcpy(dev_noise, &noiseVector[0],
						   nParticles*sizeof(ConstantVelocityNoise),
						   cudaMemcpyHostToDevice) ) ;

	// launch the kernel
	int nThreads = min(nPredict,256) ;
	int nBlocks = (nPredict+255)/256 ;
	phdPredictKernel
	<<<nBlocks, nThreads>>>
	( dev_states_prior,dev_noise,dev_states_predict ) ;

	// copy results from device
	ConstantVelocityState* states_predict = (ConstantVelocityState*)malloc(nPredict*sizeof(ConstantVelocityState)) ;
	cudaMemcpy(states_predict, dev_states_predict,
			nPredict*sizeof(ConstantVelocityState),cudaMemcpyDeviceToHost) ;
	particles.states.assign( states_predict, states_predict+nPredict ) ;

	// duplicate the PHD filter maps for the newly spawned vehicle particles,
	// and downscale particle weights
	if ( config.nPredictParticles > 1 )
	{
		vector<gaussianMixture> maps_predict ;
		vector<double> weights_predict ;
		maps_predict.clear();
		maps_predict.reserve(nPredict);
		weights_predict.clear();
		weights_predict.reserve(nPredict);
		for ( int i = 0 ; i < nParticles ; i++ )
		{
			maps_predict.insert( maps_predict.end(), config.nPredictParticles,
								 particles.maps[i] ) ;
			weights_predict.insert( weights_predict.end(), config.nPredictParticles,
									particles.weights[i] - log(config.nPredictParticles) ) ;
		}
		DEBUG_VAL(maps_predict.size()) ;
		particles.maps = maps_predict ;
		particles.weights = weights_predict ;
		particles.nParticles = nPredict ;
	}

	// log time
	cudaEventRecord( stop,0 ) ;
	cudaEventSynchronize( stop ) ;
	float elapsed ;
	cudaEventElapsedTime( &elapsed, start, stop ) ;
	fstream predictTimeFile( "predicttime.log", fstream::out|fstream::app ) ;
	predictTimeFile << elapsed << endl ;
	predictTimeFile.close() ;

	// clean up
	CUDA_SAFE_CALL( cudaFree( dev_states_prior ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_states_predict ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_noise ) ) ;
	free(states_predict) ;
}

__global__ void
birthsKernel( ConstantVelocityState* particles, int nParticles,
		RangeBearingMeasurement* ZZ, char* compatibleZ,
		Gaussian2D* births)
{
	__shared__ unsigned int birthCounter ;
	int tid = threadIdx.x ;
	if ( tid == 0 )
		birthCounter = 0 ;
	__syncthreads() ;
	int stateIdx = blockIdx.x  ;
	int offset = stateIdx*blockDim.x ;
	ConstantVelocityState s = particles[stateIdx] ;
	if ( !compatibleZ[offset+tid] )
	{
		unsigned int birthIdx = atomicAdd(&birthCounter, 1) ;
		birthIdx += offset ;
		RangeBearingMeasurement z = ZZ[tid] ;
		REAL theta = z.bearing + s.ptheta ;
		REAL dx = z.range*cos(theta) ;
		REAL dy = z.range*sin(theta) ;
		REAL J[4] ;
		J[0] = 	dx/z.range ;
		J[1] = dy/z.range ;
		J[2] = -dy ;
		J[3] = dx ;
		births[birthIdx].mean[0] = s.px + dx ;
		births[birthIdx].mean[1] = s.py + dy ;
		births[birthIdx].cov[0] = J[0]*J[0]*pow(dev_config.stdRange*dev_config.birthNoiseFactor,2)
				+ J[2]*J[2]*pow(dev_config.stdBearing*dev_config.birthNoiseFactor,2) ;
		births[birthIdx].cov[1] = J[0]*pow(dev_config.stdRange*dev_config.birthNoiseFactor,2)*J[1]
				+ J[2]*pow(dev_config.stdBearing*dev_config.birthNoiseFactor,2)*J[3] ;
		births[birthIdx].cov[2] = births[birthIdx].cov[1] ;
		births[birthIdx].cov[3] = J[1]*J[1]*pow(dev_config.stdRange*dev_config.birthNoiseFactor,2)
				+ J[3]*J[3]*pow(dev_config.stdBearing*dev_config.birthNoiseFactor,2) ;
	//	makePositiveDefinite( births[birthIdx].cov) ;
		births[birthIdx].weight = dev_config.birthWeight ;
	}
}

void addBirths(ParticleSLAM& particles, measurementSet measurements )
{
	cudaEvent_t start, stop ;
	cudaEventCreate( &start ) ;
	cudaEventCreate( &stop ) ;
	cudaEventRecord( start, 0 ) ;

	// allocate inputs on device
//	DEBUG_MSG("Allocating inputs") ;
	ConstantVelocityState* d_particles ;
	RangeBearingMeasurement* d_measurements ;
	char* devCompatibleZ ;
	vector<char> compatibleZ ;
	int nMeasurements = measurements.size() ;
    int nParticles = particles.nParticles ;
    if ( particles.compatibleZ.size() > 0 && config.gatedBirths > 0 )
	{
        compatibleZ = particles.compatibleZ ;
	}
	else
	{
		compatibleZ.assign(nParticles*nMeasurements,0) ;
	}
	size_t particlesSize = nParticles*sizeof(ConstantVelocityState) ;
	size_t measurementsSize = nMeasurements*sizeof(RangeBearingMeasurement) ;
	CUDA_SAFE_CALL(cudaMalloc( (void**)&d_particles, particlesSize ) );
	CUDA_SAFE_CALL(cudaMalloc( (void**)&d_measurements, measurementsSize ) ) ;
	CUDA_SAFE_CALL(cudaMalloc( (void**)&devCompatibleZ, nParticles*nMeasurements*sizeof(char) ) ) ;

	CUDA_SAFE_CALL(
				cudaMemcpy( d_particles, &particles.states[0], particlesSize,
							cudaMemcpyHostToDevice ) ) ;
	CUDA_SAFE_CALL(
				cudaMemcpy( d_measurements, &measurements[0], measurementsSize,
							cudaMemcpyHostToDevice ) ) ;
	CUDA_SAFE_CALL(
				cudaMemcpy( devCompatibleZ, &compatibleZ[0],
							nParticles*nMeasurements*sizeof(char),
							cudaMemcpyHostToDevice ) ) ;

	// allocate outputs on device
//	DEBUG_MSG("Allocating outputs") ;
	Gaussian2D* d_births ;
	int nBirths = nMeasurements*nParticles ;
	size_t birthsSize = nBirths*sizeof(Gaussian2D) ;
	cudaMalloc( (void**)&d_births, birthsSize ) ;

	// call the kernel
//	DEBUG_MSG("Launching Kernel") ;
	cudaError errcode ;
	if ( (errcode = cudaPeekAtLastError()) != cudaSuccess )
	{
		cout << "Error before kernel launch: " << cudaGetErrorString(errcode) << endl ;
		exit(0) ;
	}
	birthsKernel<<<nParticles, nMeasurements>>>( d_particles, nParticles,
			d_measurements, devCompatibleZ, d_births ) ;

	// retrieve outputs from device
//	DEBUG_MSG("Saving birth terms") ;
	Gaussian2D *births = new Gaussian2D[nBirths] ;
	cudaMemcpy( births, d_births, birthsSize, cudaMemcpyDeviceToHost ) ;
	vector<Gaussian2D> birthVector(births, births + nBirths) ;
	vector<Gaussian2D>::iterator i ;
	int n = 0 ;
	for ( i = birthVector.begin() ; i != birthVector.end() ; i+= nMeasurements )
	{
		int offset = n*nMeasurements ;
		int nRealBirths = 0 ;
		for ( int j = 0 ; j<nMeasurements ; j++ )
		{
			if ( !compatibleZ[offset+j] )
				nRealBirths++ ;
		}
        particles.maps[n].insert(particles.maps[n].end(),i,i+nRealBirths) ;
		n++ ;
	}
//	cout << "Map 1: " << endl ;
//	for ( int n = 0 ; n < particles->maps[1].size() ; n++ )
//	{
//		cout << "Weight: " << particles->maps[1][n].weight <<
//				" Mean: (" << particles->maps[1][n].mean[0] << "," << particles->maps[1][n].mean[1] << ")" <<
//				" Covariance: (" << particles->maps[1][n].cov[0] << "," << particles->maps[1][n].cov[1] << "," <<
//				particles->maps[1][n].cov[2] << "," << particles->maps[1][n].cov[3] << ")" << endl ;
//	}

	cudaEventRecord( stop, 0 ) ;
	cudaEventSynchronize( stop ) ;
	float elapsed ;
	cudaEventElapsedTime( &elapsed, start, stop ) ;
	fstream birthsTimeFile("birthtime.log", fstream::out|fstream::app ) ;
	birthsTimeFile << elapsed << endl ;
	birthsTimeFile.close() ;
	delete[] births ;
	cudaFree(d_particles) ;
	cudaFree(d_measurements) ;
	cudaFree(d_births) ;
	cudaFree(devCompatibleZ) ;
}

/// determine which features are in range
/*!
  * Each thread block handles a single particle. The threads in the block
  * evaluate the range and bearing [blockDim] features in parallel, looping
  * through all of the particle's features.

    \param predictedFeatures Features from all particles concatenated into a
        single array
    \param mapSizes Number of features in each particle, so that the function
        knows where the boundaries are in predictedFeatures
    \param nParticles Total number of particles
    \param poses Array of particle poses
    \param inRange Pointer to boolean array that is filled by the function.
        For each feature in predictedFeatures that is in range of its
        respective particle, the corresponding entry in this array is set to
        true
    \param nInRange Pointer to integer array that is filled by the function.
        Should be allocated to have [nParticles] elements. Each entry
        represents the number of in range features for each particle.
  */
__global__ void
computeInRangeKernel( Gaussian2D *predictedFeatures, int* mapSizes, int nParticles,
				ConstantVelocityState* poses, char* inRange, int* nInRange )
{
    int tid = threadIdx.x ;

    // total number of predicted features per block
    int nFeaturesBlock ;
    // number of inrange features in the particle
    __shared__ int nInRangeBlock ;
    // vehicle pose of the thread block
    ConstantVelocityState blockPose ;

    Gaussian2D feature ;
    for ( int p = 0 ; p < nParticles ; p += gridDim.x )
    {
		if ( p + blockIdx.x < nParticles )
        {
            int predictIdx = 0 ;
            // compute the indexing offset for this particle
            int mapIdx = p + blockIdx.x ;
            for ( int i = 0 ; i < mapIdx ; i++ )
                predictIdx += mapSizes[i] ;
            // particle-wide values
			if ( tid == 0 )
				nInRangeBlock = 0 ;
            blockPose = poses[mapIdx] ;
            nFeaturesBlock = mapSizes[mapIdx] ;
            __syncthreads() ;

            // loop through features
            for ( int i = 0 ; i < nFeaturesBlock ; i += blockDim.x )
            {
				if ( tid+i < nFeaturesBlock )
                {
                    // index of thread feature
					int featureIdx = predictIdx + tid + i ;
                    feature = predictedFeatures[featureIdx] ;

                    // default value
					inRange[featureIdx] = 0 ;

                    // compute the predicted measurement
                    REAL dx = feature.mean[0] - blockPose.px ;
                    REAL dy = feature.mean[1] - blockPose.py ;
                    REAL r2 = dx*dx + dy*dy ;
                    REAL r = sqrt(r2) ;
                    REAL bearing = wrapAngle(atan2f(dy,dx) - blockPose.ptheta) ;
					if ( r < dev_config.maxRange &&
						 fabs(bearing) < dev_config.maxBearing )
                    {
						atomicAdd( &nInRangeBlock, 1 ) ;
						inRange[featureIdx] = 1 ;
                    }
                }
            }
            // store nInrange
			__syncthreads() ;
            if ( tid == 0 )
            {
                nInRange[mapIdx] = nInRangeBlock ;
            }
        }
    }
}

/// compute partially updated weights and updated means & covariances
/**
  \param features Array of all Gaussians from all particles concatenated together
  \param map_sizes Integer array indicating the number of features per particle.
  \param n_particles Number of particles
  \param n_measurements Number of measurements
  \param poses Array of particle poses
  \param w_partial Array of partially updated weights computed by kernel
  */
__global__ void
cphdPreUpdateKernel(Gaussian2D *features, int* map_sizes,
		int n_particles, int n_measurements, ConstantVelocityState* poses,
		Gaussian2D* updated_features, REAL* w_partial )

{
	int tid = threadIdx.x + blockIdx.x*blockDim.x ;
	int map_idx = -1 ;
	int count = 0 ;
	while ( count <= tid )
	{
		map_idx++ ;
		count += (n_measurements+1)*map_sizes[map_idx] ;
	}
	int n_features = map_sizes[map_idx] ;
	int offset = count - n_features*(n_measurements+1) ;
	int feature_idx = floor( (float)(tid-offset)/(n_measurements) ) ;

	if ( feature_idx == n_features ) // non-detect thread
	{
		int predict_idx = tid - feature_idx*n_measurements - offset ;
		updated_features[tid] = features[predict_idx] ;
	}
	else // update thread
	{
		int z_idx = tid - feature_idx*n_measurements - offset ;

		Gaussian2D feature = features[feature_idx] ;
		Gaussian2D updated_feature ;
		RangeBearingMeasurement z = Z[z_idx] ;
		ConstantVelocityState pose = poses[map_idx] ;

		// predicted measurement
		REAL dx = feature.mean[0] - pose.px ;
		REAL dy = feature.mean[1] - pose.py ;
		REAL r2 = dx*dx + dy*dy ;
		REAL r = sqrt(r2) ;
		REAL bearing = wrapAngle(atan2f(dy,dx) - pose.ptheta) ;
		REAL featurePd = 0 ;

		// probability of detection
		if ( r <= dev_config.maxRange && fabsf(bearing) <= dev_config.maxBearing )
			featurePd = dev_config.pd ;

		// declare matrices
		REAL J[4] = {0,0,0,0} ;
		REAL sigma[4] = {0,0,0,0} ;
		REAL sigmaInv[4] = {0,0,0,0} ;
		REAL K[4] = {0,0,0,0} ;
		REAL detSigma = 0 ;

		// measurement jacobian wrt feature
		J[0] = dx/r ;
		J[2] = dy/r ;
		J[1] = -dy/r2 ;
		J[3] = dx/r2 ;

		// BEGIN Maple-Generated expressions
	#define P feature.cov
	#define S sigmaInv
		// innovation covariance
		sigma[0] = (P[0] * J[0] + J[2] * P[1]) * J[0] + (J[0] * P[2] + P[3] * J[2]) * J[2] + pow(dev_config.stdRange,2) ;
		sigma[1] = (P[0] * J[1] + J[3] * P[1]) * J[0] + (J[1] * P[2] + P[3] * J[3]) * J[2];
		sigma[2] = (P[0] * J[0] + J[2] * P[1]) * J[1] + (J[0] * P[2] + P[3] * J[2]) * J[3];
		sigma[3] = (P[0] * J[1] + J[3] * P[1]) * J[1] + (J[1] * P[2] + P[3] * J[3]) * J[3] + pow(dev_config.stdBearing,2) ;

		// enforce symmetry
		sigma[1] = (sigma[1]+sigma[2])/2 ;
		sigma[2] = sigma[1] ;
	//			makePositiveDefinite(sigma) ;

		detSigma = sigma[0]*sigma[3] - sigma[1]*sigma[2] ;
		sigmaInv[0] = sigma[3]/detSigma ;
		sigmaInv[1] = -sigma[1]/detSigma ;
		sigmaInv[2] = -sigma[2]/detSigma ;
		sigmaInv[3] = sigma[0]/detSigma ;

		// Kalman gain
		K[0] = S[0]*(P[0]*J[0] + P[2]*J[2]) + S[1]*(P[0]*J[1] + P[2]*J[3]) ;
		K[1] = S[0]*(P[1]*J[0] + P[3]*J[2]) + S[1]*(P[1]*J[1] + P[3]*J[3]) ;
		K[2] = S[2]*(P[0]*J[0] + P[2]*J[2]) + S[3]*(P[0]*J[1] + P[2]*J[3]) ;
		K[3] = S[2]*(P[1]*J[0] + P[3]*J[2]) + S[3]*(P[1]*J[1] + P[3]*J[3]) ;

		// Updated covariance (Joseph Form)
		updated_feature.cov[0] = ((1 - K[0] * J[0] - K[2] * J[1]) * P[0] + (-K[0] * J[2] - K[2] * J[3]) * P[1]) * (1 - K[0] * J[0] - K[2] * J[1]) + ((1 - K[0] * J[0] - K[2] * J[1]) * P[2] + (-K[0] * J[2] - K[2] * J[3]) * P[3]) * (-K[0] * J[2] - K[2] * J[3]) + pow(K[0], 2) * dev_config.stdRange*dev_config.stdRange + pow(K[2], 2) * dev_config.stdBearing*dev_config.stdBearing;
		updated_feature.cov[2] = ((1 - K[0] * J[0] - K[2] * J[1]) * P[0] + (-K[0] * J[2] - K[2] * J[3]) * P[1]) * (-K[1] * J[0] - K[3] * J[1]) + ((1 - K[0] * J[0] - K[2] * J[1]) * P[2] + (-K[0] * J[2] - K[2] * J[3]) * P[3]) * (1 - K[1] * J[2] - K[3] * J[3]) + K[0] * dev_config.stdRange*dev_config.stdRange * K[1] + K[2] * dev_config.stdBearing*dev_config.stdBearing * K[3];
		updated_feature.cov[1] = ((-K[1] * J[0] - K[3] * J[1]) * P[0] + (1 - K[1] * J[2] - K[3] * J[3]) * P[1]) * (1 - K[0] * J[0] - K[2] * J[1]) + ((-K[1] * J[0] - K[3] * J[1]) * P[2] + (1 - K[1] * J[2] - K[3] * J[3]) * P[3]) * (-K[0] * J[2] - K[2] * J[3]) + K[0] * dev_config.stdRange*dev_config.stdRange * K[1] + K[2] * dev_config.stdBearing*dev_config.stdBearing * K[3];
		updated_feature.cov[3] = ((-K[1] * J[0] - K[3] * J[1]) * P[0] + (1 - K[1] * J[2] - K[3] * J[3]) * P[1]) * (-K[1] * J[0] - K[3] * J[1]) + ((-K[1] * J[0] - K[3] * J[1]) * P[2] + (1 - K[1] * J[2] - K[3] * J[3]) * P[3]) * (1 - K[1] * J[2] - K[3] * J[3]) + pow(K[1], 2) * dev_config.stdRange*dev_config.stdRange + pow(K[3], 2) * dev_config.stdBearing*dev_config.stdBearing;
	#undef P
	#undef S

		// innovation
		REAL innov[2] = {0,0} ;
		innov[0] = z.range - r ;
		innov[1] = wrapAngle(z.bearing - bearing) ;

		// updated mean
		updated_feature.mean[0] = feature.mean[0] + K[0]*innov[0] + K[2]*innov[1] ;
		updated_feature.mean[1] = feature.mean[1] + K[1]*innov[0] + K[3]*innov[1] ;

		// single-object likelihood
		REAL dist = innov[0]*innov[0]*sigmaInv[0] +
				innov[0]*innov[1]*(sigmaInv[1] + sigmaInv[2]) +
				innov[1]*innov[1]*sigmaInv[3] ;

		// partially updated weight
		updated_feature.weight = -0.5*dist + log(feature.weight) + log(dev_config.pd)
				- log(2*M_PI) - 0.5*log(detSigma) ;

		updated_features[tid] = updated_feature ;

		int w_idx = 0 ;
		for ( int i = 0 ; i < map_idx ; i++ )
			w_idx += map_sizes[i] ;
		w_idx += feature_idx*n_measurements + z_idx ;
		w_partial[w_idx] = updated_feature.weight ;
	}
}

/// computes the elementary symmetric polynomial coefficients
/**
  This kernel produces the coefficients of the elementary symmentric function
  for the CPHD update

  \param w_partial Array of partially updated weights
  \param map_sizes Number of features per particle
  \param n_measurements Number of measurements
  \param esf Array of ESF coefficients computed by kernel
  \param esfd Array of ESF coefficients, with each measurement omitted
  */
__global__ void
computeEsfKernel( REAL* w_partial, int* map_sizes, int n_measurements,
				  REAL* esf, REAL* esfd )
{
	extern __shared__ REAL sdata[] ;
	REAL* lambda = (REAL*)sdata ;
	REAL* esf_shared = (REAL*)lambda[n_measurements] ;

	// determine indexing offsets
	int tid = threadIdx.x ;
	int map_idx = blockIdx.x ;
	int block_offset = 0 ;
	for ( int i = 0 ; i < map_idx ; i++ )
	{
		block_offset += map_sizes[i]*n_measurements ;
	}
	int n_features = map_sizes[map_idx] ;

	// compute lambda
	lambda[tid] = 0 ;
	int idx = tid ;
	for ( int j = 0 ; j < n_features ; j++ )
	{
		lambda[tid] += w_partial[idx] ;
		idx += n_features ;
	}
	__syncthreads() ;

	// compute full esf using recursive algorithm
	esf_shared[tid+1] = 0 ;
	int esf_offset = map_idx*(n_measurements+1) ;
	if ( tid == 0 )
	{
		esf_shared[0] = 1 ;
		esf[esf_offset] = 1 ;
	}
	__syncthreads() ;
	for ( int m = 0 ; m < n_measurements ; m++ )
	{
		REAL tmp1 = esf_shared[tid+1] ;
		REAL tmp2 = esf_shared[tid] ;
		__syncthreads() ;
		if ( tid < m+1 )
			esf_shared[tid+1] = tmp1 - lambda[m]*tmp2 ;
		__syncthreads() ;
	}
	esf[esf_offset+tid+1] = esf_shared[tid+1] ;

	// compute esf's for detection terms
	for ( int m = 0 ; m < n_measurements ; m++ )
	{
		int esfd_offset = n_measurements*n_measurements*map_idx + m*n_measurements ;
		esf_shared[tid+1] = 0 ;
		if ( tid == 0 )
		{
			esf_shared[0] = 1 ;
			esfd[esfd_offset] = 1 ;
		}
		for ( int n = 0 ; n < n_measurements ; n++ )
		{
			REAL tmp1 = esf_shared[tid+1] ;
			REAL tmp2 = esf_shared[tid] ;
			__syncthreads() ;
			if ( tid < n+1 && n != m )
			{
				esf_shared[tid+1] = tmp1 - lambda[n]*tmp2 ;
			}
			__syncthreads() ;
		}
		if ( tid < (n_measurements-1) )
			esfd[esfd_offset+tid+1] = esf_shared[tid+1]
	}
}

/// compute the multi-object likelihoods for the CPHD update
/**
  This kernel computes the terms denoted as Psi in Vo's Analytic CPHD paper, and
  their inner products with the predicted cardinality distribution. It also
  produces the updated cardinality
  */
__global__ void
computePsiKernel( REAL* cn_predict, REAL* esf, REAL* esfd, REAL* w_partial,
				  int n_measurements, REAL* wsum,
				  REAL* cn_update, REAL* innerprod_psi0, REAL* innerprod_psi1,
				  REAL* innerprod_psi1d )
{
	int n = threadIdx.x ;
	REAL psi0 = 0 ;
	REAL psi1 = 0 ;
	int stop_idx = min(n,n_measurements) ;
	int map_idx = blockIdx.x ;
	int cn_offset = (dev_config.maxCardinality+1)*map_idx ;
	int esf_offset = (n_measurements+1)*map_idx ;
	REAL max_val0, max_val1 ;
	extern __shared__ sdata[] ;

	// compute (log) PSI0(n) and PSI1(n), using log-sum-exp
	for ( int j = 0 ; j <= stop_idx ; j++ )
	{
		// PSI0
		REAL p_coeff = dev_C[n+j*(dev_config.maxCardinality+1)]
				+ dev_factorial[j] ;
		REAL aux = dev_factorial[n_measurements-j]
				+ cn_predict[cn_offset+n_measurements-j] + esf[esf_offset+ j] ;
		REAL tmp =  aux + p_coeff + (n-j)*log(1-dev_config.pd) - j*wsum[map_idx] ;
		if ( j = 0 )
		{
			max_val0 = tmp ;
			psi0 += 1 ;
		}
		else
		{
			psi0 += exp(tmp-max_val0) ;
		}

		// PSI1
		p_coeff = dev_C[n+(j+1)*(dev_config.maxCardinality+1)]
				+ dev_factorial[j+1] ;
		tmp = aux + p_coeff + (n-(j+1))*log(1-dev_config.pd) - (j+1)*wsum[map_idx] ;
		if ( j = 0 )
		{
			max_val1 = tmp ;
			psi1 += 1 ;
		}
		else
		{
			psi1 += exp(tmp-max_val0) ;
		}
	}
	psi0 = log(psi0) + max_val0 ;
	psi1 = log(psi1) + max_val1 ;

	// (log) inner product of PSI0 and predicted cardinality distribution, using
	// log-sum-exp trick
	maxByReduction( sdata, psi0+cn_predict[cn_offset+n], n ) ;
	max_val0 = sdata[0] ;
	__syncthreads() ;
	sumByReduction( sdata, exp( psi0+cn_predict[cn_offset+n] - max_val0 ), n ) ;
	if ( n == 0 )
		innerprod_psi0[map_idx] = log(sdata[0]) + max_val0 ;

	// (log) inner product of PSI1 and predicted cardinality distribution, using
	// log-sum-exp trick
	maxByReduction( sdata, psi1+cn_predict[cn_offset+n], n ) ;
	max_val0 = sdata[0] ;
	__syncthreads() ;
	sumByReduction( sdata, exp( psi1+cn_predict[cn_offset+n] - max_val0 ), n ) ;
	if ( n == 0 )
		innerprod_psi1[map_idx] = log(sdata[0]) + max_val0 ;

	// PSI1 detection terms
	stop_idx = min(n_measurements - 1, n) ;
	int esfd_offset = map_idx * n_measurements * n_measurements ;
	for ( int m = 0 ; m < n_measurements ; m++ )
	{
		REAL psi1d = 0 ;
		for ( int j = 0 ; j <= stop_idx ; j++ )
		{
			REAL p_coeff = dev_C[n+(j+1)*(dev_config.maxCardinality+1)]
					+ dev_factorial[j+1] ;
			REAL tmp = dev_factorial[n_measurements-j-1]
					+ cn_predict[cn_offset+n_measurements-j-1]
					+ esfd[esfd_offset+j] + p_coeff + (n-(j+1))*log(1-dev_config.pd)
					- (j+1)*wsum[map_idx] ;
			if ( j == 0 )
			{
				max_val0 = tmp ;
				psi1d = 1 ;
			}
			else
			{
				psi1d += exp(tmp - max_val0) ;
			}
		}
		psi1d = log(psi1d) + max_val0 ;
		maxByReduction( sdata, psi1d+cn_predict[cn_offset+n], n ) ;
		max_val0 = sdata[0] ;
		__syncthreads() ;
		sumByReduction( sdata, exp(psi1d+cn_predict[cn_offset+n]-max_val0), n ) ;
		if ( tid == 0 )
			innerprod_psi1d[map_idx*n_measurements+m] = log(sdata[0]) + max_val0 ;
	}

	// compute log updated cardinality
	cn_update[cn_offset+n] = cn_predict[cn_offset+n] + psi0
			- innerprod_psi0[map_idx] ;
}

/// perform the gaussian mixture CPHD weight update
/**
  This kernel takes the results produced by the previous three kernels in the
  CPHD pipeline (PreUpdate, ComputeEsf, and ComputePsi) and applies them to
  update the weights of the Gaussian Mixture as in Vo's paper
  */
__global__ void
cphdUpdateKernel( REAL* w_partial, int* map_sizes, int n_measurements,
				  REAL* innerprod_psi0, REAL* innerprod_psi1,
				  REAL* innerprod_psi1d, bool* merged_flags,
				  Gaussian2D* updated_features, REAL* particle_weights )
{
	int z_idx = threadIdx.x ;
	int map_idx = blockIdx.x ;
	int offset = 0 ;
	for ( int i = 0 ; i < map_sizes[map_idx] ; i++ )
	{
		offset += map_sizes[i]*(n_measurements+1) ;
	}

	REAL psi1d = innerprod_psi1d[n_measurements*map_idx+z_idx] ;
	for ( int j = 0 ; j < map_sizes[map_idx] ; j++ )
	{
		REAL tmp = psi1d - innerprod_psi0[map_idx] + log(dev_config.clutterRate)
				- log(dev_config.clutterDensity) + log(w_partial[offset+z_idx]);
		updated_features[offset+z_idx].weight = exp(tmp) ;
		if ( exp(tmp) > dev_config.minFeatureWeight )
			merged_flags[offset + z_idx] = false ;
		else
			merged_flags[offset + z_idx] = true ;
		offset += n_measurements ;
	}

	// non-detection updates
	for ( int j = 0 ; j < map_sizes[map_idx] ; j += blockDim.x )
	{
		int nondetect_idx = offset + z_idx ;
		REAL tmp = log(updated_features[nondetect_idx])
				+ innerprod_psi1[map_idx] - innerprod_psi0[map_idx]
				+ log(1-dev_config.pd) ;
		updated_features[nondetect_idx] = exp(tmp) ;
		if ( exp(tmp) > dev_config.minFeatureWeight )
			merged_flags[nondetect_idx] = false ;
		else
			merged_flags[nondetect_idx] = true ;
		offset += blockDim.x ;
	}
}

/// perform the gaussian mixture PHD update, and the reduce the resulting mixture
/**
  PHD update algorithm as in Vo & Ma 2006. Gaussian mixture reduction (merging),
  as in the clustering algorithm by Salmond 1990.
    \param inRangeFeatures Array of in-range Gaussians, with which the PHD
        update will be performed
    \param mapSizes Integer array of sizes of each particle's map
    \param nMeasurements Number of measurements
    \param poses Array of particle poses
    \param compatibleZ char array which will be computed by the kernel.
        Indicates which measurements have been found compatible with an existing
        gaussian.
    \param updatedFeatures Stores the updated Gaussians computed by the kernel
    \param mergedFeatures Stores the post-merge updated Gaussians computed by
        the kernel.
    \param mergedSizes Stores the number of Gaussians left in each map after
        merging. This is required because the same amount of memory is allocated
        for both updatedFeatures and mergedFeatures. The indexing boundaries for
        the maps will be the same, but only the first n gaussians after the
        boundary will be valid for the mergedFeatures array.
    \param mergedFlags Array of booleans used by the merging algorithm to keep
        track of which features have already be merged.
    \param particleWeights New particle weights after PHD update
  */
__global__ void
phdUpdateKernel(Gaussian2D *inRangeFeatures, int* mapSizes,
		int nParticles, int nMeasurements, ConstantVelocityState* poses,
		char* compatibleZ,Gaussian2D *updatedFeatures,
		bool *mergedFlags, REAL *particleWeights )
{
	// shared memory variables
	__shared__ ConstantVelocityState pose ;
	__shared__ REAL sdata[256] ;
//	__shared__ Gaussian2D maxFeature ;
//	__shared__ REAL wMerge ;
//	__shared__ REAL meanMerge[2] ;
//	__shared__ REAL covMerge[4] ;
//	__shared__ int mergedSize ;
	__shared__ REAL particle_weight ;
    __shared__ REAL cardinality_predict ;
    __shared__ REAL cardinality_updated ;
	__shared__ int mapIdx ;
	__shared__ int updateOffset ;
	__shared__ int nFeatures ;
	__shared__ int nUpdate ;
	__shared__ int predictIdx ;


	// initialize variables
	int tid = threadIdx.x ;
	// pre-update variables
	REAL featurePd = 0 ;
	REAL dx, dy, r2, r, bearing ;
	REAL J[4] = {0,0,0,0} ;
	REAL K[4] = {0,0,0,0} ;
	REAL sigma[4] = {0,0,0,0} ;
	REAL sigmaInv[4] = {0,0,0,0} ;
	REAL covUpdate[4] = {0,0,0,0} ;
	REAL detSigma = 0 ;
	Gaussian2D feature ;

	// update variables
	RangeBearingMeasurement z ;
	REAL innov[2] = {0,0} ;
	REAL meanUpdate[2] = {0,0} ;
	REAL dist = 0 ;
	REAL logLikelihood = 0 ;
	REAL wPartial = 0 ;
	REAL weightUpdate = 0 ;
	int updateIdx = 0 ;
	// loop over particles
	for ( int p = 0 ; p < nParticles ; p += gridDim.x )
	{
		if ( p + blockIdx.x < nParticles )
		{
			// initialize shared variables
			if ( tid == 0 )
			{
				mapIdx = p + blockIdx.x ;
				predictIdx = 0 ;
				for ( int i = 0 ; i < mapIdx ; i++ )
					predictIdx += mapSizes[i] ;
				updateOffset = predictIdx*(nMeasurements+1) ;
				nFeatures = mapSizes[mapIdx] ;
				nUpdate = nFeatures*(nMeasurements+1) ;
				pose = poses[mapIdx] ;
				particle_weight = 0 ;
	//			mergedSize = 0 ;
	//			mergedSizes[mapIdx] = nUpdate ;
				cardinality_predict = 0.0 ;
				cardinality_updated = 0.0 ;
			}
			__syncthreads() ;

			if ( tid < nMeasurements )
				compatibleZ[mapIdx*nMeasurements + tid] = 0 ;
			for ( int j = 0 ; j < nFeatures ; j += blockDim.x )
			{
				int feature_idx = j + tid ;
				if ( feature_idx < nFeatures )
				{
					// get the feature corresponding to the current thread
					feature = inRangeFeatures[predictIdx+feature_idx] ;

					/*
					 * PRECOMPUTE UPDATE COMPONENTS
					 */
					// predicted measurement
					dx = feature.mean[0] - pose.px ;
					dy = feature.mean[1] - pose.py ;
					r2 = dx*dx + dy*dy ;
					r = sqrt(r2) ;
					bearing = wrapAngle(atan2f(dy,dx) - pose.ptheta) ;

					// probability of detection
					if ( r <= dev_config.maxRange && fabsf(bearing) <= dev_config.maxBearing )
						featurePd = dev_config.pd ;
					else
						featurePd = 0 ;

					// measurement jacobian wrt feature
					J[0] = dx/r ;
					J[2] = dy/r ;
					J[1] = -dy/r2 ;
					J[3] = dx/r2 ;

					// BEGIN Maple-Generated expressions
			#define P feature.cov
			#define S sigmaInv
					// innovation covariance
					sigma[0] = (P[0] * J[0] + J[2] * P[1]) * J[0] + (J[0] * P[2] + P[3] * J[2]) * J[2] + pow(dev_config.stdRange,2) ;
					sigma[1] = (P[0] * J[1] + J[3] * P[1]) * J[0] + (J[1] * P[2] + P[3] * J[3]) * J[2];
					sigma[2] = (P[0] * J[0] + J[2] * P[1]) * J[1] + (J[0] * P[2] + P[3] * J[2]) * J[3];
					sigma[3] = (P[0] * J[1] + J[3] * P[1]) * J[1] + (J[1] * P[2] + P[3] * J[3]) * J[3] + pow(dev_config.stdBearing,2) ;

					// enforce symmetry
					sigma[1] = (sigma[1]+sigma[2])/2 ;
					sigma[2] = sigma[1] ;
		//			makePositiveDefinite(sigma) ;

					detSigma = sigma[0]*sigma[3] - sigma[1]*sigma[2] ;
					sigmaInv[0] = sigma[3]/detSigma ;
					sigmaInv[1] = -sigma[1]/detSigma ;
					sigmaInv[2] = -sigma[2]/detSigma ;
					sigmaInv[3] = sigma[0]/detSigma ;

					// Kalman gain
					K[0] = S[0]*(P[0]*J[0] + P[2]*J[2]) + S[1]*(P[0]*J[1] + P[2]*J[3]) ;
					K[1] = S[0]*(P[1]*J[0] + P[3]*J[2]) + S[1]*(P[1]*J[1] + P[3]*J[3]) ;
					K[2] = S[2]*(P[0]*J[0] + P[2]*J[2]) + S[3]*(P[0]*J[1] + P[2]*J[3]) ;
					K[3] = S[2]*(P[1]*J[0] + P[3]*J[2]) + S[3]*(P[1]*J[1] + P[3]*J[3]) ;

					// Updated covariance (Joseph Form)
					covUpdate[0] = ((1 - K[0] * J[0] - K[2] * J[1]) * P[0] + (-K[0] * J[2] - K[2] * J[3]) * P[1]) * (1 - K[0] * J[0] - K[2] * J[1]) + ((1 - K[0] * J[0] - K[2] * J[1]) * P[2] + (-K[0] * J[2] - K[2] * J[3]) * P[3]) * (-K[0] * J[2] - K[2] * J[3]) + pow(K[0], 2) * dev_config.stdRange*dev_config.stdRange + pow(K[2], 2) * dev_config.stdBearing*dev_config.stdBearing;
					covUpdate[2] = ((1 - K[0] * J[0] - K[2] * J[1]) * P[0] + (-K[0] * J[2] - K[2] * J[3]) * P[1]) * (-K[1] * J[0] - K[3] * J[1]) + ((1 - K[0] * J[0] - K[2] * J[1]) * P[2] + (-K[0] * J[2] - K[2] * J[3]) * P[3]) * (1 - K[1] * J[2] - K[3] * J[3]) + K[0] * dev_config.stdRange*dev_config.stdRange * K[1] + K[2] * dev_config.stdBearing*dev_config.stdBearing * K[3];
					covUpdate[1] = ((-K[1] * J[0] - K[3] * J[1]) * P[0] + (1 - K[1] * J[2] - K[3] * J[3]) * P[1]) * (1 - K[0] * J[0] - K[2] * J[1]) + ((-K[1] * J[0] - K[3] * J[1]) * P[2] + (1 - K[1] * J[2] - K[3] * J[3]) * P[3]) * (-K[0] * J[2] - K[2] * J[3]) + K[0] * dev_config.stdRange*dev_config.stdRange * K[1] + K[2] * dev_config.stdBearing*dev_config.stdBearing * K[3];
					covUpdate[3] = ((-K[1] * J[0] - K[3] * J[1]) * P[0] + (1 - K[1] * J[2] - K[3] * J[3]) * P[1]) * (-K[1] * J[0] - K[3] * J[1]) + ((-K[1] * J[0] - K[3] * J[1]) * P[2] + (1 - K[1] * J[2] - K[3] * J[3]) * P[3]) * (1 - K[1] * J[2] - K[3] * J[3]) + pow(K[1], 2) * dev_config.stdRange*dev_config.stdRange + pow(K[3], 2) * dev_config.stdBearing*dev_config.stdBearing;

			#undef P
			#undef S
		//	#undef J0
		//	#undef J1
		//	#undef J2
		//	#undef J3
					/*
					 * END PRECOMPUTE UPDATE COMPONENTS
					 */

					// save the non-detection term
					int nonDetectIdx = updateOffset + feature_idx ;
					REAL nonDetectWeight = feature.weight * (1-featurePd) ;
					updatedFeatures[nonDetectIdx].weight = nonDetectWeight ;
					updatedFeatures[nonDetectIdx].mean[0] = feature.mean[0] ;
					updatedFeatures[nonDetectIdx].mean[1] = feature.mean[1] ;
					updatedFeatures[nonDetectIdx].cov[0] = feature.cov[0] ;
					updatedFeatures[nonDetectIdx].cov[1] = feature.cov[1] ;
					updatedFeatures[nonDetectIdx].cov[2] = feature.cov[2] ;
					updatedFeatures[nonDetectIdx].cov[3] = feature.cov[3] ;
	//				mergedFlags[nonDetectIdx] = false ;
					if ( nonDetectWeight >= dev_config.minFeatureWeight )
						mergedFlags[nonDetectIdx] = false ;
					else
						mergedFlags[nonDetectIdx] = true ;
				}
				else
				{
					featurePd = 0 ;
					feature.weight = 0 ;
					covUpdate[0] = 0 ;
					covUpdate[1] = 0 ;
					covUpdate[2] = 0 ;
					covUpdate[3] = 0 ;
				}

				// predicted cardinality = sum of weights*pd
				sumByReduction(sdata, feature.weight*featurePd, tid) ;
				if ( tid == 0 )
					cardinality_predict = sdata[0] ;
				__syncthreads() ;

				/*
				 * LOOP THROUGH MEASUREMENTS AND DO UPDATE
				 */
				for (int i = 0 ; i < nMeasurements ; i++ )
				{
					z = Z[i] ;
					if ( feature_idx < nFeatures)
					{
						updateIdx = updateOffset + (i+1)*nFeatures + feature_idx ;
						// compute innovation
						innov[0] = z.range - r ;
						innov[1] = wrapAngle( z.bearing - bearing ) ;
						// compute updated mean
						meanUpdate[0] = feature.mean[0] + K[0]*innov[0] + K[2]*innov[1] ;
						meanUpdate[1] = feature.mean[1] + K[1]*innov[0] + K[3]*innov[1] ;
						// compute single object likelihood
						dist = innov[0]*innov[0]*sigmaInv[0] +
								innov[0]*innov[1]*(sigmaInv[1] + sigmaInv[2]) +
								innov[1]*innov[1]*sigmaInv[3] ;
						// TODO: does this need to be atomic?
						if ( dist < BIRTH_COMPAT_THRESHOLD )
							compatibleZ[i+mapIdx*nMeasurements] |= 1 ;
						// partially updated weight
						if ( featurePd > 0 )
						{
							logLikelihood = log(featurePd) + log(feature.weight)
									- 0.5*dist- log(2*M_PI) - 0.5*log(detSigma) ;
							wPartial = logLikelihood ;
						}
						else
						{
							wPartial = 0 ;
						}
						// save updated gaussian with partially updated weight
						updatedFeatures[updateIdx].weight = wPartial ;
						updatedFeatures[updateIdx].mean[0] = meanUpdate[0] ;
						updatedFeatures[updateIdx].mean[1] = meanUpdate[1] ;
						updatedFeatures[updateIdx].cov[0] = covUpdate[0] ;
						updatedFeatures[updateIdx].cov[1] = covUpdate[1] ;
						updatedFeatures[updateIdx].cov[2] = covUpdate[2] ;
						updatedFeatures[updateIdx].cov[3] = covUpdate[3] ;
					}
				}
			}

			// compute the weight normalizers
			for ( int i = 0 ; i < nMeasurements ; i++ )
			{
				REAL log_normalizer = 0 ;
				REAL val = 0 ;
				// find the maximum from all the log-values, including the clutter term
				for ( int j = 0 ; j < nFeatures ; j += blockDim.x )
				{
					int feature_idx = j+tid ;
					if ( feature_idx < nFeatures )
					{
						updateIdx = updateOffset + (i+1)*nFeatures + feature_idx ;
						wPartial = updatedFeatures[updateIdx].weight ;
					}
					else
					{
						wPartial = log(dev_config.clutterDensity) ;
					}
					maxByReduction( sdata, wPartial, tid ) ;
					if ( val == 0 || sdata[0] > val)
						val = sdata[0] ;
					__syncthreads() ;
				}

				// do the exponent sum
				REAL sum = 0 ;
				for ( int j = 0 ; j < nFeatures ; j += blockDim.x )
				{
					int feature_idx = j+tid ;
					if ( feature_idx < nFeatures )
					{
						updateIdx = updateOffset + (i+1)*nFeatures + feature_idx ;
						wPartial = exp(updatedFeatures[updateIdx].weight-val) ;
					}
					else
					{
						wPartial = 0 ;
					}
					sumByReduction( sdata, wPartial, tid ) ;
					sum += sdata[0] ;
					__syncthreads() ;
				}
				if ( tid == 0 && dev_config.particleWeighting == 2 )
					particle_weight += sum * exp(val) ;
				sum += exp(log(dev_config.clutterDensity)-val) ;

				// add back the offset value
				log_normalizer = log(sum) + val ;

				if ( tid == 0 && dev_config.particleWeighting == 0 )
					particle_weight += log_normalizer ;
				__syncthreads() ;
				for ( int j = 0 ; j < nFeatures ; j += blockDim.x )
				{
					int feature_idx = j + tid ;
					if ( feature_idx < nFeatures )
					{
						updateIdx = updateOffset + (i+1)*nFeatures + feature_idx ;
						weightUpdate = exp(updatedFeatures[updateIdx].weight - log_normalizer) ;
						updatedFeatures[updateIdx].weight = weightUpdate ;
						if ( weightUpdate >= dev_config.minFeatureWeight)
						{
							mergedFlags[updateIdx] = false ;
						}
						else
						{
							mergedFlags[updateIdx] = true ;
						}
					}
				}
			}

			// Cluster-PHD particle weighting
			if ( dev_config.particleWeighting == 0 )
			{
				__syncthreads() ;
				if ( tid == 0 )
				{
					particle_weight -= cardinality_predict ;
//					if ( isnan(particle_weight) )
//						particle_weight = 0 ;
					particleWeights[mapIdx] = particle_weight ;
				}
			}
			// Vo-EmptyMap particle weighting
			else if ( dev_config.particleWeighting == 1 )
			{
				// updated cardinality = sum of updated weights
				for ( int i = 0 ; i < nUpdate ; i += blockDim.x )
				{
					// to avoid divergence in the reduction function call, load weight
					// into temp variable first
					if ( tid + i < nUpdate )
						wPartial = updatedFeatures[updateOffset+i+tid].weight ;
					else
						wPartial = 0.0 ;
					sumByReduction( sdata, wPartial, tid );
					if ( tid == 0 )
						cardinality_updated += sdata[0] ;
					__syncthreads() ;
				}

				// compute sum of log clutter densities by parallel reduction
				if ( tid < nMeasurements )
					wPartial = log(dev_config.clutterDensity) ;
				else
					wPartial = 0 ;
				sumByReduction( sdata, wPartial, tid ) ;
				if ( tid == 0 )
				{
					particleWeights[mapIdx] = sdata[0]
							+ cardinality_updated - cardinality_predict
							- dev_config.clutterDensity*nMeasurements  ;
				}
			}
			// Single-Feature IID cluster assumption
			else if ( dev_config.particleWeighting == 2 )
			{
				if ( tid == 0 )
				{
					particle_weight /= (dev_config.clutterDensity*cardinality_predict) ;
					particle_weight += (1-dev_config.pd) ;
					particleWeights[mapIdx] = log(particle_weight) ;
				}
			}
		}
	}
}

__global__ void
phdUpdateMergeKernel(Gaussian2D *updatedFeatures,
					 Gaussian2D *mergedFeatures, int *mergedSizes,
					 bool *mergedFlags, int* mapSizes, int nParticles, int nMeasurements )
{
	__shared__ Gaussian2D maxFeature ;
	__shared__ REAL wMerge ;
	__shared__ REAL meanMerge[2] ;
	__shared__ REAL covMerge[4] ;
	__shared__ REAL sdata[256] ;
	__shared__ int mergedSize ;
	__shared__ int updateOffset ;
	__shared__ int nUpdate ;
	int tid = threadIdx.x ;
	REAL dist ;
	REAL innov[2] ;
	Gaussian2D feature ;
	// loop over particles
	for ( int p = 0 ; p < nParticles ; p += gridDim.x )
	{
		int mapIdx = p + blockIdx.x ;
		if ( mapIdx <= nParticles )
		{
			// initialize shared vars
			if ( tid == 0)
			{
				updateOffset = 0 ;
				for ( int i = 0 ; i < mapIdx ; i++ )
				{
					updateOffset += (nMeasurements+1)*mapSizes[i] ;
				}
				nUpdate = (nMeasurements+1)*mapSizes[mapIdx] ;
				mergedSize = 0 ;
			}
			__syncthreads() ;
			while(true)
			{
				// initialize the output values to defaults
				if ( tid == 0 )
				{
					maxFeature.weight = -1 ;
					wMerge = 0 ;
					meanMerge[0] = 0 ;
					meanMerge[1] = 0 ;
					covMerge[0] = 0 ;
					covMerge[1] = 0 ;
					covMerge[2] = 0 ;
					covMerge[3] = 0 ;
				}
				sdata[tid] = -1 ;
				__syncthreads() ;
				// find the maximum feature with parallel reduction
				for ( int i = updateOffset ; i < updateOffset + nUpdate ; i += blockDim.x)
				{
					int idx = i + tid ;
					if ( idx < (updateOffset + nUpdate) )
					{
						if( !mergedFlags[idx] )
						{
							if (sdata[tid] == -1 ||
								updatedFeatures[(unsigned int)sdata[tid]].weight < updatedFeatures[idx].weight )
							{
								sdata[tid] = idx ;
							}
						}
					}
				}
				__syncthreads() ;
				for ( int s = blockDim.x/2 ; s > 0 ; s >>= 1 )
				{
					if ( tid < s )
					{
						if ( sdata[tid] == -1 )
							sdata[tid] = sdata[tid+s] ;
						else if ( sdata[tid+s] >= 0 )
						{
							if(updatedFeatures[(unsigned int)sdata[tid]].weight <
							updatedFeatures[(unsigned int)sdata[tid+s]].weight )
							{
								sdata[tid] = sdata[tid+s] ;
							}
						}

					}
					__syncthreads() ;
				}
				if ( sdata[0] == -1 || maxFeature.weight == 0 )
					break ;
				else if(tid == 0)
					maxFeature = updatedFeatures[ (unsigned int)sdata[0] ] ;
				__syncthreads() ;

				// find features to merge with max feature
				REAL sval0 = 0 ;
				REAL sval1 = 0 ;
				REAL sval2 = 0 ;
				for ( int i = updateOffset ; i < updateOffset + nUpdate ; i += blockDim.x )
				{
					int idx = tid + i ;
					if ( idx < updateOffset+nUpdate )
					{
						if ( !mergedFlags[idx] )
						{
							feature = updatedFeatures[idx] ;
							dist = computeHellingerDist(maxFeature, feature ) ;
							if ( dist < dev_config.minSeparation )
							{
								sval0 += feature.weight ;
								sval1 += feature.mean[0]*feature.weight ;
								sval2 += feature.mean[1]*feature.weight ;
							}
						}
					}
				}
				sumByReduction(sdata, sval0, tid) ;
				if ( tid == 0 )
					wMerge = sdata[0] ;
				__syncthreads() ;
				if ( wMerge == 0 )
					break ;
				sumByReduction( sdata, sval1, tid ) ;
				if ( tid == 0 )
					meanMerge[0] = sdata[0]/wMerge ;
				__syncthreads() ;
				sumByReduction( sdata, sval2, tid ) ;
				if ( tid == 0 )
					meanMerge[1] = sdata[0]/wMerge ;
				__syncthreads() ;


				// merge the covariances
				sval0 = 0 ;
				sval1 = 0 ;
				sval2 = 0 ;
		//		sval3 = 0 ;
				for ( int i = updateOffset ; i < updateOffset+nUpdate ; i += blockDim.x )
				{
					int idx = tid + i ;
					if ( idx < updateOffset+nUpdate )
					{
						if (!mergedFlags[idx])
						{
							feature = updatedFeatures[idx] ;
							dist = computeHellingerDist(maxFeature, feature ) ;
							if ( dist < dev_config.minSeparation )
							{
								innov[0] = meanMerge[0] - feature.mean[0] ;
								innov[1] = meanMerge[1] - feature.mean[1] ;
								sval0 += (feature.cov[0] + innov[0]*innov[0])*feature.weight ;
								sval1 += (feature.cov[1] +feature.cov[2] + 2*innov[0]*innov[1])*feature.weight/2 ;
								sval2 += (feature.cov[3] + innov[1]*innov[1])*feature.weight ;
								mergedFlags[idx] = true ;
							}
						}
					}
				}
				sumByReduction(sdata, sval0, tid) ;
				if ( tid == 0 )
					covMerge[0] = sdata[0]/wMerge ;
				__syncthreads() ;
				sumByReduction( sdata, sval1, tid ) ;
				if ( tid == 0 )
				{
					covMerge[1] = sdata[0]/wMerge ;
					covMerge[2] = covMerge[1] ;
				}
				__syncthreads() ;
				sumByReduction( sdata, sval2, tid ) ;
				if ( tid == 0 )
				{
					covMerge[3] = sdata[0]/wMerge ;
					int mergeIdx = updateOffset + mergedSize ;
					mergedFeatures[mergeIdx].weight = wMerge ;
					mergedFeatures[mergeIdx].mean[0] = meanMerge[0] ;
					mergedFeatures[mergeIdx].mean[1] = meanMerge[1] ;
					mergedFeatures[mergeIdx].cov[0] = covMerge[0] ;
					mergedFeatures[mergeIdx].cov[1] = covMerge[1] ;
					mergedFeatures[mergeIdx].cov[2] = covMerge[2] ;
					mergedFeatures[mergeIdx].cov[3] = covMerge[3] ;
					mergedSize++ ;
				}
				__syncthreads() ;
			}
			__syncthreads() ;
			// save the merged map size
			if ( tid == 0 )
				mergedSizes[mapIdx] = mergedSize ;
		}
	} // end loop over particles
	return ;
}


ParticleSLAM
phdUpdate(ParticleSLAM& particles, measurementSet measurements)
{
	// make a copy of the particles
    ParticleSLAM particlesPreMerge(particles) ;

    ///////////////////////////////////////////////////////////////////////////
    //
	// concatenate all the maps together for parallel processing
    //
    ///////////////////////////////////////////////////////////////////////////
	gaussianMixture concat ;
    int nParticles = particles.nParticles ;
	int nMeasurements = measurements.size() ;
	vector<int> mapSizes(nParticles) ;
	int nThreads = 0 ;
	int totalFeatures = 0 ;
	DEBUG_VAL(nParticles) ;
	for ( unsigned int n = 0 ; n < nParticles ; n++ )
	{
        concat.insert( concat.end(), particles.maps[n].begin(),
                particles.maps[n].end()) ;
        mapSizes[n] = particles.maps[n].size() ;
//		DEBUG_VAL(mapSizes[n]) ;

		// keep track of largest map feature count
		if ( mapSizes[n] > nThreads )
			nThreads = mapSizes[n] ;
		nThreads = min(nThreads,256) ;
		totalFeatures += mapSizes[n] ;
	}
	if ( totalFeatures == 0 )
	{
		DEBUG_MSG("no features, exiting early") ;
		return particlesPreMerge;
	}

    ///////////////////////////////////////////////////////////////////////////
    //
    // split features into in/out range parts
    //
    ///////////////////////////////////////////////////////////////////////////

    // allocate device memory
	Gaussian2D* dev_maps = NULL ;
	int* dev_map_sizes = NULL ;
	int* dev_n_in_range = NULL ;
	char* dev_in_range = NULL ;
	ConstantVelocityState* dev_poses = NULL ;
    CUDA_SAFE_CALL(
                cudaMalloc( (void**)&dev_maps,
                            totalFeatures*sizeof(Gaussian2D) ) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc( (void**)&dev_map_sizes,
                            nParticles*sizeof(int) ) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc( (void**)&dev_n_in_range,
                            nParticles*sizeof(int) ) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc( (void**)&dev_in_range,
							totalFeatures*sizeof(char) ) ) ;
    CUDA_SAFE_CALL(
            cudaMalloc( (void**)&dev_poses,
                        nParticles*sizeof(ConstantVelocityState) ) ) ;

    // copy inputs
    CUDA_SAFE_CALL(
        cudaMemcpy( dev_maps, &concat[0], totalFeatures*sizeof(Gaussian2D),
                    cudaMemcpyHostToDevice )
    ) ;
    CUDA_SAFE_CALL(
				cudaMemcpy( dev_map_sizes, &mapSizes[0], nParticles*sizeof(int),
                    cudaMemcpyHostToDevice )
    ) ;
    CUDA_SAFE_CALL(
                cudaMemcpy(dev_poses,&particles.states[0],
                           nParticles*sizeof(ConstantVelocityState),
                           cudaMemcpyHostToDevice)
    ) ;

    // kernel launch
	DEBUG_MSG("launching computeInRangeKernel") ;
	DEBUG_VAL(nThreads) ;
	computeInRangeKernel<<<nParticles,nThreads>>>
		( dev_maps, dev_map_sizes, nParticles, dev_poses, dev_in_range, dev_n_in_range) ;
	CUDA_SAFE_THREAD_SYNC();

    // allocate outputs
//	char* in_range = (char*)malloc( totalFeatures*sizeof(char) ) ;
//	if( !(in_range)) {                                                     \
//		fprintf(stderr, "Host malloc failure in file '%s' in line %i\n",     \
//				__FILE__, __LINE__);                                         \
//		exit(EXIT_FAILURE);                                                  \
//	}
	vector<char> in_range(totalFeatures) ;
    vector<int> n_in_range_vec(nParticles) ;

    // copy outputs
    CUDA_SAFE_CALL(
				cudaMemcpy( &in_range[0],dev_in_range,totalFeatures*sizeof(char),
                    cudaMemcpyDeviceToHost )
    ) ;
    CUDA_SAFE_CALL(
        cudaMemcpy( &n_in_range_vec[0],dev_n_in_range,nParticles*sizeof(int),
                    cudaMemcpyDeviceToHost )
    ) ;

    // get total number of in-range features
    int n_in_range = 0 ;
    vector<int> n_out_range_vec(nParticles) ;
    for ( int i = 0 ; i < nParticles ; i++ )
    {
        n_in_range += n_in_range_vec[i] ;
        n_out_range_vec[i] = particles.maps[i].size() -  n_in_range_vec[i] ;
    }
    int n_out_range = totalFeatures - n_in_range ;

    // divide features into in-range/out-of-range parts
	DEBUG_VAL(n_in_range) ;
    DEBUG_VAL(n_out_range) ;
    gaussianMixture features_in(n_in_range) ;
    gaussianMixture features_out(n_out_range ) ;
    int idx_in = 0 ;
    int idx_out = 0 ;
    for ( int i = 0 ; i < totalFeatures ; i++ )
    {
		if (in_range[i] == 1)
            features_in[idx_in++] = concat[i] ;
        else
            features_out[idx_out++] = concat[i] ;
    }

    ///////////////////////////////////////////////////////////////////////////
    //
    // Do PHD update with only in-range features
    //
    ///////////////////////////////////////////////////////////////////////////

//	n_in_range_vec = mapSizes ;
//	n_in_range = totalFeatures ;
//	n_out_range = 0 ;
//	features_in = concat ;


    // check for memory limit for storing measurements in constant mem
	if ( nMeasurements > MAXMEASUREMENTS )
	{
		DEBUG_MSG("Warning: maximum number of measurements per time step exceeded") ;
//		DEBUG_VAL(nMeasurements-MAXMEASUREMENTS) ;
		nMeasurements = MAXMEASUREMENTS ;
	}
    DEBUG_VAL(nMeasurements) ;

//    // check device memory limit and split into multiple kernel launches if
//    // necessary
//	int nUpdate = n_in_range*(nMeasurements+1) ;
////	int nUpdate = totalFeatures*(nMeasurements+1) ;
//    size_t requiredMem =
//            n_in_range*sizeof(Gaussian2D) +         // dev_maps
//            nParticles*sizeof(int) +                    // dev_map_offsets
//            nParticles*sizeof(ConstantVelocityState) +  // dev_poses
//            nParticles*nMeasurements*sizeof(char) +     // dev_compatible_z
//            nUpdate*sizeof(Gaussian2D) +                // dev_maps_update
//            nUpdate*sizeof(Gaussian2D) +                // dev_maps_merged
//            nParticles*sizeof(int) +                    // dev_merged_map_sizes
//            nParticles*sizeof(REAL) +                   // dev_particle_weights
//            nUpdate*sizeof(bool) ;                      // dev_merged_flags
//		DEBUG_VAL(requiredMem) ;
//	int numLaunches = ceil( requiredMem/deviceMemLimit ) ;
//	if ( numLaunches > 1 )
//	{
//        DEBUG_MSG( "Device memory limit exceeded, will launch multiple kernels in serial" ) ;
//		DEBUG_VAL( numLaunches ) ;
//	}

//    // perform an (exclusive) prefix scan on the map sizes to determine indexing
//    // offsets for each map
//    vector<int> map_offsets_in(nParticles,0) ;
//    vector<int> map_offsets_out(nParticles,0) ;
//    int sum_in = 0 ;
//    int sum_out = 0 ;
//    for ( int i = 0 ; i < nParticles ; i++ )
//    {
//        map_offsets_in[i] = sum_in ;
//        map_offsets_out[i] = sum_out ;
//        sum_in += n_in_range_vec[i] ;
//        sum_out += n_out_range_vec[i] ;
//    }

    // allocate device memory
	int *dev_map_sizes_inrange = NULL ;
	int* dev_n_merged = NULL ;
	char* dev_compatible_z = NULL ;
	Gaussian2D* dev_maps_inrange = NULL ;
	Gaussian2D* dev_maps_updated = NULL ;
	Gaussian2D* dev_maps_merged = NULL ;
	REAL* dev_particle_weights = NULL ;
	bool* dev_merged_flags = NULL ;

	// cphd-only variables
	REAL* dev_wpartial = NULL ;
	REAL* dev_esf = NULL ;
	REAL* dev_esfd = NULL ;
	REAL* dev_innerprod0 = NULL ;
	REAL* dev_innerprod1 = NULL ;
	REAL* dev_innerprod1d = NULL ;
	REAL* dev_cnpredict = NULL ;
	REAL* dev_cnupdate = NULL ;

	CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_maps_inrange,
								n_in_range*sizeof(Gaussian2D) ) ) ;
	CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_map_sizes_inrange,
								nParticles*sizeof(int) ) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc((void**)&dev_compatible_z,
                           nParticles*nMeasurements*sizeof(char) ) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc((void**)&dev_maps_updated,
                           nUpdate*sizeof(Gaussian2D)) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc((void**)&dev_particle_weights,
                           nParticles*sizeof(REAL) ) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc((void**)&dev_maps_merged,
                           nUpdate*sizeof(Gaussian2D)) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc((void**)&dev_n_merged,
                           nParticles*sizeof(int)) ) ;
    CUDA_SAFE_CALL(
                cudaMalloc((void**)&dev_merged_flags,
                           nUpdate*sizeof(bool)) ) ;
	if ( config.filterType == CPHD_TYPE )
	{
		size_t cn_size = nParticles*(config.maxCardinality+1)*sizeof(REAL) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_cnpredict, cn_size ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_cnupdate, cn_size ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_wpartial,
								nMeasurements*totalFeatures*sizeof(REAL) ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_esf,
								(nMeasurements+1)*nParticles*sizeof(REAL) ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_esfd,
								nMeasurements*nMeasurements*nParticles*sizeof(REAL) ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_innerprod0,
								nParticles*sizeof(REAL) ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_innerprod1,
								nParticles*sizeof(REAL) ) ) ;
		CUDA_SAFE_CALL(
					cudaMalloc( (void**)&dev_innerprod1d,
								nParticles*nMeasurements*sizeof(REAL) ) ) ;
	}
    // copy inputs
    CUDA_SAFE_CALL(
		cudaMemcpy( dev_maps_inrange, &features_in[0],
                    n_in_range*sizeof(Gaussian2D),
                    cudaMemcpyHostToDevice )
    ) ;
    CUDA_SAFE_CALL(
		cudaMemcpy( dev_map_sizes_inrange, &n_in_range_vec[0],
                    nParticles*sizeof(int),
                    cudaMemcpyHostToDevice )
		) ;
	CUDA_SAFE_CALL(
				cudaMemcpyToSymbol( Z, &measurements[0],
									nMeasurements*sizeof(RangeBearingMeasurement) ) ) ;
	if ( config.filterType == CPHD_TYPE )
	{
		CUDA_SAFE_CALL(
					cudaMemcpy( dev_cnpredict, cn_predict_inrange,
								nParticles*(config.maxCardinality+1)*sizeof(REAL) ) ) ;
	}

    // launch kernel
	int nBlocks = min(nParticles,32768) ;
	DEBUG_MSG("launching phdUpdateKernel") ;
	phdUpdateKernel<<<nBlocks,256>>>
		( dev_maps_inrange, dev_map_sizes_inrange, nParticles, nMeasurements, dev_poses,
		  dev_compatible_z, dev_maps_updated,
          dev_merged_flags,dev_particle_weights ) ;
	CUDA_SAFE_THREAD_SYNC() ;
	DEBUG_MSG("launching phdUpdateMergeKernel") ;
	phdUpdateMergeKernel<<<nBlocks,256>>>
		( dev_maps_updated, dev_maps_merged, dev_n_merged, dev_merged_flags,
		  dev_map_sizes_inrange, nParticles, nMeasurements );
	CUDA_SAFE_THREAD_SYNC() ;

    // allocate outputs
	DEBUG_MSG("Allocating update and merge outputs") ;
    Gaussian2D* maps_merged = (Gaussian2D*)malloc( nUpdate*sizeof(Gaussian2D) ) ;
	Gaussian2D* maps_updated = (Gaussian2D*)malloc( nUpdate*sizeof(Gaussian2D) ) ;
    int* map_sizes_merged = (int*)malloc( nParticles*sizeof(int) ) ;
    char* compatible_z = (char*)malloc( nParticles*nMeasurements*sizeof(char) ) ;
	REAL* particle_weights = (REAL*)malloc(nParticles*sizeof(REAL)) ;

    // copy outputs
	DEBUG_MSG("cudaMemcpy") ;
    CUDA_SAFE_CALL(
                cudaMemcpy(compatible_z,dev_compatible_z,
                           nParticles*nMeasurements*sizeof(char),
                           cudaMemcpyDeviceToHost ) ) ;
    CUDA_SAFE_CALL(
				cudaMemcpy(particle_weights,dev_particle_weights,
						   nParticles*sizeof(REAL),
						   cudaMemcpyDeviceToHost ) ) ;

	CUDA_SAFE_CALL(
				cudaMemcpy( maps_updated, dev_maps_updated,
							nUpdate*sizeof(Gaussian2D),
							cudaMemcpyDeviceToHost ) ) ;

    CUDA_SAFE_CALL(
                cudaMemcpy( maps_merged, dev_maps_merged,
                            nUpdate*sizeof(Gaussian2D),
                            cudaMemcpyDeviceToHost ) ) ;
    CUDA_SAFE_CALL(
                cudaMemcpy( map_sizes_merged, dev_n_merged,
                            nParticles*sizeof(int),
                            cudaMemcpyDeviceToHost ) ) ;

    // free memory
	DEBUG_MSG("Freeing memory") ;


    ///////////////////////////////////////////////////////////////////////////
    //
    // Save updated maps
    //
    ///////////////////////////////////////////////////////////////////////////

	DEBUG_MSG("Saving update results") ;
    int offset_updated = 0 ;
    int offset_out = 0 ;
    REAL weightSum = 0 ;

    for ( int i = 0 ; i < nParticles ; i++ )
	{
//		DEBUG_VAL(map_sizes_merged[i]) ;
//		DEBUG_VAL(offset_updated) ;
		particles.maps[i].assign(maps_merged+offset_updated,
							 maps_merged+offset_updated+map_sizes_merged[i]) ;
//		particles.maps[i].assign( maps_updated+offset_updated,
//								maps_updated+offset_updated+n_in_range_vec[i]*(nMeasurements+1) ) ;
//		DEBUG_VAL(i) ;
//		DEBUG_VAL(particles.weights[i]) ;
//		DEBUG_VAL(particle_weights[i]) ;
		particles.weights[i] += particle_weights[i]  ;
//		DEBUG_VAL(particles.weights[i]) ;
//		if (particles.weights[i] <= 0 )
//			particles.weights[i] = FLT_MIN ;
		particlesPreMerge.maps[i].assign( maps_updated+offset_updated,
										maps_updated+offset_updated+n_in_range_vec[i]*(nMeasurements+1) ) ;
		offset_updated += n_in_range_vec[i]*(nMeasurements+1) ;

		if ( n_out_range > 0 && n_out_range_vec[i] > 0 )
		{
			particles.maps[i].insert( particles.maps[i].end(),
								features_out.begin()+offset_out,
								features_out.begin()+offset_out+n_out_range_vec[i] ) ;
			particlesPreMerge.maps[i].insert( particlesPreMerge.maps[i].end(),
											features_out.begin()+offset_out,
											features_out.begin()+offset_out+n_out_range_vec[i] ) ;
			offset_out += n_out_range_vec[i] ;
		}
    }

    // save compatible measurement flags
	DEBUG_MSG("Save compatibleZ") ;
    particles.compatibleZ.assign( compatible_z,
                                  compatible_z+nParticles*nMeasurements) ;

    // normalize particle weights
	weightSum = logSumExp(particles.weights) ;
	DEBUG_VAL(weightSum) ;
    for (int i = 0 ; i < nParticles ; i++ )
	{
		particles.weights[i] -= weightSum ;
//		DEBUG_VAL(particles.weights[i])
	}

	// normalize again
	weightSum = logSumExp(particles.weights) ;
	DEBUG_VAL(weightSum) ;
	for (int i = 0 ; i < nParticles ; i++ )
	{
		particles.weights[i] -= weightSum ;
//		DEBUG_VAL(particles.weights[i])
	}
	weightSum = logSumExp(particles.weights) ;
	DEBUG_VAL(weightSum) ;

    particlesPreMerge.weights = particles.weights ;


//	////////////////////////////////////////////////////////
//	//
//	// Downsample shotgunned particles
//	//
//	////////////////////////////////////////////////////////
//	if ( config.nPredictParticles > 1 )
//	{
//		particles = resampleParticles(particles,config.nParticles) ;
//	}


    // free memory
//	DEBUG_MSG("Freeing in_range") ;
//	free(in_range) ;
	free(maps_updated) ;
	DEBUG_MSG("freeing maps_merged") ;
	free(maps_merged) ;
	DEBUG_MSG("Freeing map_sizes_merged") ;
	free(map_sizes_merged) ;
	DEBUG_MSG("particle_weights") ;
	free(particle_weights) ;
	DEBUG_MSG("Freeing compatible_z") ;
	free(compatible_z) ;

	DEBUG_MSG("Freeing dev_in_range") ;
	CUDA_SAFE_CALL( cudaFree( dev_in_range ) ) ;
	DEBUG_MSG("Freeing dev_n_in_range") ;
	CUDA_SAFE_CALL( cudaFree( dev_n_in_range ) ) ;
	DEBUG_MSG("Freeing dev_maps") ;
	CUDA_SAFE_CALL( cudaFree( dev_maps ) ) ;
	DEBUG_MSG("Freeing dev_map_sizes") ;
	CUDA_SAFE_CALL( cudaFree( dev_map_sizes ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_compatible_z ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_particle_weights ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_maps_inrange ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_poses ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_map_sizes_inrange ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_maps_merged ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_maps_updated ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_n_merged ) ) ;
	CUDA_SAFE_CALL( cudaFree( dev_merged_flags ) ) ;

	DEBUG_MSG("returning...") ;
    return particlesPreMerge ;
}

__global__ void
mergeKernelSingle( Gaussian2D *features, int nFeatures,
		Gaussian2D *mergedFeatures, bool *mergedFlags, int *nMerged)
{
    __shared__ REAL wSum[256] ;
    __shared__ REAL meanSum[256][2] ;
    __shared__ REAL covSum[256][4] ;
	__shared__ REAL wMerge ;
	__shared__ REAL meanMerge[2] ;
	__shared__ REAL covMerge[4] ;
	__shared__ Gaussian2D maxFeature ;
	int tid = threadIdx.x  ;

	// initialize variables
	for ( int i = 0 ; i < nFeatures ; i += blockDim.x )
	{
		int idx = tid + i ;
		if ( idx < nFeatures )
			mergedFlags[idx] = false ;
	}
	if ( tid == 0 )
		*nMerged = 0 ;

	Gaussian2D feature ;
	REAL innov[2] ;
	REAL dist ;
	while(true)
	{
		// find the maximum feature with parallel reduction
		if ( tid == 0 )
		{
			maxFeature.weight = -1 ;
			wMerge = 0 ;
			meanMerge[0] = 0 ;
			meanMerge[1] = 0 ;
			covMerge[0] = 0 ;
			covMerge[1] = 0 ;
			covMerge[2] = 0 ;
			covMerge[3] = 0 ;
		}
		wSum[tid] = -1 ;
		meanSum[tid][0] = -1 ;
		meanSum[tid][1] = -1 ;
		covSum[tid][0] = -1 ;
		covSum[tid][1] = -1 ;
		covSum[tid][2] = -1 ;
		covSum[tid][3] = -1 ;
		for ( int i = 0 ; i < nFeatures ; i+=blockDim.x )
		{
			int idx = tid + i ;
			if ( idx < nFeatures )
			{
				feature = features[idx] ;
				if( !mergedFlags[idx] && wSum[tid] < feature.weight )
				{
					wSum[tid] = feature.weight ;
					meanSum[tid][0] = feature.mean[0] ;
					meanSum[tid][1] = feature.mean[1] ;
					covSum[tid][0] = feature.cov[0] ;
					covSum[tid][1] = feature.cov[1] ;
					covSum[tid][2] = feature.cov[2] ;
					covSum[tid][3] = feature.cov[3] ;
				}
			}
		}
		__syncthreads() ;
//		if (tid < 256 && wSum[tid] < wSum[tid+256] )
//		{
//			wSum[tid] = wSum[tid+256] ;
//			meanSum[tid][0] = meanSum[tid+256][0] ;
//			meanSum[tid][1] = meanSum[tid+256][1] ;
//			covSum[tid][0] = covSum[tid+256][0] ;
//			covSum[tid][1] = covSum[tid+256][1] ;
//			covSum[tid][2] = covSum[tid+256][2] ;
//			covSum[tid][3] = covSum[tid+256][3] ;
//		}
		__syncthreads() ;
		if (tid < 128 && wSum[tid] < wSum[tid+128] )
		{
			wSum[tid] = wSum[tid+128] ;
			meanSum[tid][0] = meanSum[tid+128][0] ;
			meanSum[tid][1] = meanSum[tid+128][1] ;
			covSum[tid][0] = covSum[tid+128][0] ;
			covSum[tid][1] = covSum[tid+128][1] ;
			covSum[tid][2] = covSum[tid+128][2] ;
			covSum[tid][3] = covSum[tid+128][3] ;
		}
		__syncthreads() ;
		if (tid < 64 && wSum[tid] < wSum[tid+64] )
		{
			wSum[tid] = wSum[tid+64] ;
			meanSum[tid][0] = meanSum[tid+64][0] ;
			meanSum[tid][1] = meanSum[tid+64][1] ;
			covSum[tid][0] = covSum[tid+64][0] ;
			covSum[tid][1] = covSum[tid+64][1] ;
			covSum[tid][2] = covSum[tid+64][2] ;
			covSum[tid][3] = covSum[tid+64][3] ;
		}
		__syncthreads() ;

		if (tid < 32 && wSum[tid] < wSum[tid+32] )
		{
			wSum[tid] = wSum[tid+32] ;
			meanSum[tid][0] = meanSum[tid+32][0] ;
			meanSum[tid][1] = meanSum[tid+32][1] ;
			covSum[tid][0] = covSum[tid+32][0] ;
			covSum[tid][1] = covSum[tid+32][1] ;
			covSum[tid][2] = covSum[tid+32][2] ;
			covSum[tid][3] = covSum[tid+32][3] ;
		}
		__syncthreads() ;

		if (tid < 16 && wSum[tid] < wSum[tid+16] )
		{
			wSum[tid] = wSum[tid+16] ;
			meanSum[tid][0] = meanSum[tid+16][0] ;
			meanSum[tid][1] = meanSum[tid+16][1] ;
			covSum[tid][0] = covSum[tid+16][0] ;
			covSum[tid][1] = covSum[tid+16][1] ;
			covSum[tid][2] = covSum[tid+16][2] ;
			covSum[tid][3] = covSum[tid+16][3] ;
		}
		__syncthreads() ;

		if (tid < 8 && wSum[tid] < wSum[tid+8] )
		{
			wSum[tid] = wSum[tid+8] ;
			meanSum[tid][0] = meanSum[tid+8][0] ;
			meanSum[tid][1] = meanSum[tid+8][1] ;
			covSum[tid][0] = covSum[tid+8][0] ;
			covSum[tid][1] = covSum[tid+8][1] ;
			covSum[tid][2] = covSum[tid+8][2] ;
			covSum[tid][3] = covSum[tid+8][3] ;
		}
		__syncthreads() ;

		if ( tid < 4 && wSum[tid] < wSum[tid+4] )
		{
			wSum[tid] = wSum[tid+4] ;
			meanSum[tid][0] = meanSum[tid+4][0] ;
			meanSum[tid][1] = meanSum[tid+4][1] ;
			covSum[tid][0] = covSum[tid+4][0] ;
			covSum[tid][1] = covSum[tid+4][1] ;
			covSum[tid][2] = covSum[tid+4][2] ;
			covSum[tid][3] = covSum[tid+4][3] ;
		}
		__syncthreads() ;

		if ( tid < 2 && wSum[tid] < wSum[tid+2] )
		{
			wSum[tid] = wSum[tid+2] ;
			meanSum[tid][0] = meanSum[tid+2][0] ;
			meanSum[tid][1] = meanSum[tid+2][1] ;
			covSum[tid][0] = covSum[tid+2][0] ;
			covSum[tid][1] = covSum[tid+2][1] ;
			covSum[tid][2] = covSum[tid+2][2] ;
			covSum[tid][3] = covSum[tid+2][3] ;
		}
		__syncthreads() ;

		if ( tid < 1 && wSum[tid] < wSum[tid+1] )
		{
			wSum[tid] = wSum[tid+1] ;
			meanSum[tid][0] = meanSum[tid+1][0] ;
			meanSum[tid][1] = meanSum[tid+1][1] ;
			covSum[tid][0] = covSum[tid+1][0] ;
			covSum[tid][1] = covSum[tid+1][1] ;
			covSum[tid][2] = covSum[tid+1][2] ;
			covSum[tid][3] = covSum[tid+1][3] ;
		}
		__syncthreads() ;
		if ( tid == 0 )
		{
			maxFeature.weight = wSum[0] ;
			maxFeature.mean[0] = meanSum[0][0] ;
			maxFeature.mean[1] = meanSum[0][1] ;
			maxFeature.cov[0] = covSum[0][0] ;
			maxFeature.cov[1] = covSum[0][1] ;
			maxFeature.cov[2] = covSum[0][2] ;
			maxFeature.cov[3] = covSum[0][3] ;
		}
		__syncthreads() ;

		// exit when no more valid features are found
		if ( maxFeature.weight == -1 )
			break ;

		// find features to merge with max feature
		wSum[tid] = 0 ;
		meanSum[tid][0] = 0 ;
		meanSum[tid][1] = 0 ;
		for ( int i = 0 ; i < nFeatures ; i+=blockDim.x )
		{
			int idx = tid + i ;
			if ( idx < nFeatures )
			{
				if ( !mergedFlags[idx] )
				{
					feature = features[idx] ;
					dist = computeHellingerDist(maxFeature, feature) ;
                    if ( dist < dev_config.minSeparation )
					{
						wSum[tid] += feature.weight ;
						meanSum[tid][0] += feature.mean[0]*feature.weight ;
						meanSum[tid][1] += feature.mean[1]*feature.weight ;
					}
				}
			}
		}
		__syncthreads() ;
		/*
		 * sum the weights and means by parallel reduction
		 */
//		if ( tid < 256 )
//		{
//			wSum[tid] += wSum[tid+256] ;
//			meanSum[tid][0] += meanSum[tid+256][0] ;
//			meanSum[tid][1] += meanSum[tid+256][1] ;
//		}
		__syncthreads() ;
		if ( tid < 128 )
		{
			wSum[tid] += wSum[tid+128] ;
			meanSum[tid][0] += meanSum[tid+128][0] ;
			meanSum[tid][1] += meanSum[tid+128][1] ;
		}
		__syncthreads() ;
		if ( tid < 64 )
		{
			wSum[tid] += wSum[tid+64] ;
			meanSum[tid][0] += meanSum[tid+64][0] ;
			meanSum[tid][1] += meanSum[tid+64][1] ;
		}
		__syncthreads() ;
		// last warp...
		if ( tid < 32 )
		{
			wSum[tid] += wSum[tid+32] ;
			meanSum[tid][0] += meanSum[tid+32][0] ;
			meanSum[tid][1] += meanSum[tid+32][1] ;

			wSum[tid] += wSum[tid+16] ;
			meanSum[tid][0] += meanSum[tid+16][0] ;
			meanSum[tid][1] += meanSum[tid+16][1] ;

			wSum[tid] += wSum[tid+8] ;
			meanSum[tid][0] += meanSum[tid+8][0] ;
			meanSum[tid][1] += meanSum[tid+8][1] ;

			wSum[tid] += wSum[tid+4] ;
			meanSum[tid][0] += meanSum[tid+4][0] ;
			meanSum[tid][1] += meanSum[tid+4][1] ;

			wSum[tid] += wSum[tid+2] ;
			meanSum[tid][0] += meanSum[tid+2][0] ;
			meanSum[tid][1] += meanSum[tid+2][1] ;

			wSum[tid] += wSum[tid+1] ;
			meanSum[tid][0] += meanSum[tid+1][0] ;
			meanSum[tid][1] += meanSum[tid+1][1] ;
		}
		__syncthreads() ;
		// store the merged weight and mean
		if ( tid == 0 )
		{
			wMerge = wSum[0] ;
			meanMerge[0] = meanSum[0][0]/wMerge ;
			meanMerge[1] = meanSum[0][1]/wMerge ;
		}
		__syncthreads() ;

		// merge the covariances
		covSum[tid][0] = 0 ;
		covSum[tid][1] = 0 ;
		covSum[tid][2] = 0 ;
		covSum[tid][3] = 0 ;
		for ( int i = 0 ; i < nFeatures ; i+=blockDim.x )
		{
			int idx = tid + i ;
			if ( idx < nFeatures )
			{
				if (!mergedFlags[idx])
				{
					feature = features[idx] ;
					dist = computeHellingerDist(maxFeature, feature) ;
                    if ( dist < dev_config.minSeparation )
					{
						innov[0] = meanMerge[0] - feature.mean[0] ;
						innov[1] = meanMerge[1] - feature.mean[1] ;
						covSum[tid][0] += (feature.cov[0] + innov[0]*innov[0])*feature.weight ;
						covSum[tid][1] += (feature.cov[1] + innov[0]*innov[1])*feature.weight ;
						covSum[tid][2] += (feature.cov[2] + innov[0]*innov[1])*feature.weight ;
						covSum[tid][3] += (feature.cov[3] + innov[1]*innov[1])*feature.weight ;
						mergedFlags[idx] = true ;
					}
				}
			}
		}
		__syncthreads() ;

//		if ( tid < 256 )
//		{
//			covSum[tid][0] += covSum[tid+256][0] ;
//			covSum[tid][1] += covSum[tid+256][1] ;
//			covSum[tid][2] += covSum[tid+256][2] ;
//			covSum[tid][3] += covSum[tid+256][3] ;
//		}
		__syncthreads() ;

		if ( tid < 128 )
		{
			covSum[tid][0] += covSum[tid+128][0] ;
			covSum[tid][1] += covSum[tid+128][1] ;
			covSum[tid][2] += covSum[tid+128][2] ;
			covSum[tid][3] += covSum[tid+128][3] ;
		}
		__syncthreads() ;

		if ( tid < 64 )
		{
			covSum[tid][0] += covSum[tid+64][0] ;
			covSum[tid][1] += covSum[tid+64][1] ;
			covSum[tid][2] += covSum[tid+64][2] ;
			covSum[tid][3] += covSum[tid+64][3] ;
		}
		__syncthreads() ;

		// last warp...
		if ( tid < 32 )
		{
			covSum[tid][0] += covSum[tid+32][0] ;
			covSum[tid][1] += covSum[tid+32][1] ;
			covSum[tid][2] += covSum[tid+32][2] ;
			covSum[tid][3] += covSum[tid+32][3] ;

			covSum[tid][0] += covSum[tid+16][0] ;
			covSum[tid][1] += covSum[tid+16][1] ;
			covSum[tid][2] += covSum[tid+16][2] ;
			covSum[tid][3] += covSum[tid+16][3] ;

			covSum[tid][0] += covSum[tid+8][0] ;
			covSum[tid][1] += covSum[tid+8][1] ;
			covSum[tid][2] += covSum[tid+8][2] ;
			covSum[tid][3] += covSum[tid+8][3] ;

			covSum[tid][0] += covSum[tid+4][0] ;
			covSum[tid][1] += covSum[tid+4][1] ;
			covSum[tid][2] += covSum[tid+4][2] ;
			covSum[tid][3] += covSum[tid+4][3] ;

			covSum[tid][0] += covSum[tid+2][0] ;
			covSum[tid][1] += covSum[tid+2][1] ;
			covSum[tid][2] += covSum[tid+2][2] ;
			covSum[tid][3] += covSum[tid+2][3] ;

			covSum[tid][0] += covSum[tid+1][0] ;
			covSum[tid][1] += covSum[tid+1][1] ;
			covSum[tid][2] += covSum[tid+1][2] ;
			covSum[tid][3] += covSum[tid+1][3] ;
		}
		__syncthreads() ;
		// store the merged covariance
		if ( tid == 0 )
		{
			covMerge[0] = covSum[0][0]/wMerge ;
			covMerge[1] = covSum[0][1]/wMerge ;
			covMerge[2] = covSum[0][2]/wMerge ;
			covMerge[3] = covSum[0][3]/wMerge ;
		}

		// store merged gaussian in output array
		if ( tid == 0 )
		{
			int mergeIdx = *nMerged ;
			mergedFeatures[mergeIdx].weight = wMerge ;
			mergedFeatures[mergeIdx].mean[0] = meanMerge[0] ;
			mergedFeatures[mergeIdx].mean[1] = meanMerge[1] ;
			mergedFeatures[mergeIdx].cov[0] = covMerge[0] ;
			mergedFeatures[mergeIdx].cov[1] = covMerge[1] ;
			mergedFeatures[mergeIdx].cov[2] = covMerge[2] ;
			mergedFeatures[mergeIdx].cov[3] = covMerge[3] ;
			*nMerged += 1 ;
		}
		__syncthreads() ;
	}
}



void mergeGaussianMixture(gaussianMixture *GM)
{
	int nFeatures = GM->size() ;
	int nBlocks = (nFeatures + 255)/256 ;
	DEBUG_VAL(nFeatures) ;
	DEBUG_VAL(nBlocks) ;
	size_t GMSize = nFeatures*sizeof(Gaussian2D) ;
	Gaussian2D *devGaussians, *devGaussiansMerged ;

	cudaEvent_t start, stop ;
	cudaEventCreate( &start ) ;
	cudaEventCreate( &stop ) ;
	cudaEventRecord( start, 0 ) ;

//	DEBUG_MSG("Allocating inputs") ;
    CUDA_SAFE_CALL( cudaMalloc( (void**)&devGaussians, GMSize ) ) ;
    CUDA_SAFE_CALL(
                cudaMemcpy( devGaussians, &GM->front(), GMSize,
                            cudaMemcpyHostToDevice ) ) ;

//	DEBUG_MSG("Allocating outputs") ;
	int *devSizeMerged ;
	bool *devMergedFlags ;
    CUDA_SAFE_CALL( cudaMalloc( (void**)&devGaussiansMerged, GMSize ) ) ;
    CUDA_SAFE_CALL( cudaMalloc( (void**)&devSizeMerged, sizeof(int) ) ) ;
    CUDA_SAFE_CALL( cudaMalloc( (void**)&devMergedFlags, nFeatures*sizeof(bool) ) ) ;

	DEBUG_MSG("Launching kernel...") ;
	// kernel call
    mergeKernelSingle<<<1,256>>>( devGaussians, nFeatures,
			devGaussiansMerged, devMergedFlags, devSizeMerged ) ;;

	DEBUG_MSG("Copying outputs from device") ;
	int nMerged  ;
	Gaussian2D *maxFeatures = new Gaussian2D[nBlocks] ;
	bool *hostMergedFlags = new bool[nFeatures] ;
//	cudaMemcpy( maxFeatures, devMaxFeature, nBlocks*sizeof(Gaussian2D), cudaMemcpyDeviceToHost ) ;
    CUDA_SAFE_CALL(
                cudaMemcpy( &nMerged, devSizeMerged, sizeof(int),
                            cudaMemcpyDeviceToHost ) ) ;
    CUDA_SAFE_CALL(
                cudaMemcpy( hostMergedFlags, devMergedFlags,
                            nFeatures*sizeof(bool), cudaMemcpyDeviceToHost ) ) ;
	DEBUG_VAL(nMerged) ;

	gaussianMixture gaussiansMerged(nMerged) ;
	Gaussian2D *tmp = new Gaussian2D[nMerged] ;
    CUDA_SAFE_CALL(
                cudaMemcpy( tmp, devGaussiansMerged, nMerged*sizeof(Gaussian2D),
                            cudaMemcpyDeviceToHost ) ) ;
	GM->assign(tmp, tmp+nMerged) ;

	cudaEventRecord( stop, 0 ) ;
	cudaEventSynchronize( stop ) ;
	float elapsed ;
	cudaEventElapsedTime( &elapsed, start, stop ) ;
	fstream mergeTimeFile("mergetime.log", fstream::out|fstream::app ) ;
	mergeTimeFile << elapsed << endl ;
	mergeTimeFile.close() ;

	delete[] tmp ;
	delete[] hostMergedFlags ;
	cudaFree(devSizeMerged) ;
	cudaFree(devGaussians) ;
	cudaFree(devGaussiansMerged) ;
	cudaFree( devMergedFlags ) ;
}


ParticleSLAM resampleParticles( ParticleSLAM oldParticles, int n_new_particles )
{
	if ( n_new_particles < 0 )
	{
		n_new_particles = oldParticles.nParticles ;
	}
//	unsigned int nParticles = oldParticles.nParticles ;
	ParticleSLAM newParticles(n_new_particles) ;
	int compatible_z_step = oldParticles.compatibleZ.size()/oldParticles.nParticles ;
	newParticles.compatibleZ.reserve( n_new_particles*compatible_z_step );

	double interval = 1.0/n_new_particles ;
	double r = randu01() * interval ;
	double c = exp(oldParticles.weights[0]) ;
	int i = 0 ;
	DEBUG_VAL(interval) ;
	for ( int j = 0 ; j < n_new_particles ; j++ )
	{
//		DEBUG_VAL(j) ;
//		DEBUG_VAL(r) ;
//		DEBUG_VAL(c) ;
		while( r > c )
		{
			i++ ;
			// sometimes the weights don't exactly add up to 1, so i can run
			// over the indexing bounds. When this happens, find the most highly
			// weighted particle and fill the rest of the new samples with it
			if ( i >= oldParticles.nParticles || i < 0 || isnan(i) )
			{
				DEBUG_VAL(r) ;
				DEBUG_VAL(c) ;
				double max_weight = -1 ;
				int max_idx = -1 ;
				for ( int k = 0 ; k < oldParticles.nParticles ; k++ )
				{
					DEBUG_MSG("Warning: particle weights don't add up to 1!s") ;
					if ( exp(oldParticles.weights[k]) > max_weight )
					{
						max_weight = exp(oldParticles.weights[k]) ;
						max_idx = k ;
					}

				}
				i = max_idx ;
				// set c = 2 so that this while loop is never entered again
				c = 2 ;
				break ;
			}
			c += exp(oldParticles.weights[i]) ;
		}
//		DEBUG_VAL(i) ;
		newParticles.weights[j] = log(interval) ;
		newParticles.states[j] = oldParticles.states[i] ;
		newParticles.maps[j] = oldParticles.maps[i] ;
		newParticles.compatibleZ.insert(newParticles.compatibleZ.end(),
										oldParticles.compatibleZ.begin()+i*compatible_z_step,
										oldParticles.compatibleZ.begin()+(i+1)*compatible_z_step ) ;
		r += interval ;
	}
	return newParticles ;
}

gaussianMixture computeExpectedMap(ParticleSLAM particles)
// concatenate all particle maps into a single slam particle and then call the
// existing gaussian pruning algorithm ;
{
	gaussianMixture concat ;
	int totalFeatures = 0 ;
	DEBUG_MSG("Concatenating Maps") ;
	for ( int n = 0 ; n < particles.nParticles ; n++ )
	{
		int oldEnd = concat.size() ;
		concat.insert(concat.end(),
				particles.maps[n].begin(),particles.maps[n].end() ) ;
		int nFeatures = particles.maps[n].size() ;
		for ( int i = oldEnd ; i < oldEnd + nFeatures; i++ )
		{
			concat[i].weight *= exp(particles.weights[n]) ;
		}
		totalFeatures += particles.maps[n].size() ;
	}
	if ( totalFeatures == 0 )
	{
		DEBUG_MSG("All maps are empty") ;
	}
	else
	{
		DEBUG_MSG("Merging concatenated maps") ;
		mergeGaussianMixture(&concat) ;
	}
	return concat ;
}

bool expectedFeaturesPredicate( Gaussian2D g )
{
    return (g.weight <= config.minExpectedFeatureWeight) ;
}

void recoverSlamState(ParticleSLAM particles, ConstantVelocityState& expectedPose,
		gaussianMixture& expectedMap)
{
	if ( particles.nParticles > 1 )
	{
		// calculate the weighted mean of the particle poses
		expectedPose.px = 0 ;
		expectedPose.py = 0 ;
		expectedPose.ptheta = 0 ;
		expectedPose.vx = 0 ;
		expectedPose.vy = 0 ;
		expectedPose.vtheta = 0 ;
		for ( int i = 0 ; i < particles.nParticles ; i++ )
		{
			double exp_weight = exp(particles.weights[i]) ;
			expectedPose.px += exp_weight*particles.states[i].px ;
			expectedPose.py += exp_weight*particles.states[i].py ;
			expectedPose.ptheta += exp_weight*particles.states[i].ptheta ;
			expectedPose.vx += exp_weight*particles.states[i].vx ;
			expectedPose.vy += exp_weight*particles.states[i].vy ;
			expectedPose.vtheta += exp_weight*particles.states[i].vtheta ;
		}
//		gaussianMixture tmpMap = computeExpectedMap(particles) ;
//		tmpMap.erase(
//						remove_if( tmpMap.begin(), tmpMap.end(),
//								expectedFeaturesPredicate),
//						tmpMap.end() ) ;
//		*expectedMap = tmpMap ;
		// just get the map from the most highly-weighted particle
		double max_weight = -INFINITY ;
		int max_idx = -1 ;
		for ( int i = 0 ; i < particles.nParticles ; i++ )
		{
			if ( particles.weights[i] > max_weight )
			{
				max_idx = i ;
				max_weight = particles.weights[i] ;
			}
		}
		DEBUG_VAL(max_idx) ;
		gaussianMixture tmpMap( particles.maps[max_idx] ) ;
		tmpMap.erase(
				remove_if( tmpMap.begin(), tmpMap.end(),
						expectedFeaturesPredicate),
				tmpMap.end() ) ;
		expectedPose = particles.states[0] ;
		expectedMap = tmpMap ;
	}
	else
	{
		gaussianMixture tmpMap( particles.maps[0] ) ;
		tmpMap.erase(
				remove_if( tmpMap.begin(), tmpMap.end(),
						expectedFeaturesPredicate),
				tmpMap.end() ) ;
		expectedPose = particles.states[0] ;
		expectedMap = tmpMap ;
	}
}

/// copy the configuration structure to constant device memory
void
setDeviceConfig( const SlamConfig& config )
{
	CUDA_SAFE_CALL(cudaMemcpyToSymbol( "dev_config", &config, sizeof(SlamConfig) ) ) ;
}

