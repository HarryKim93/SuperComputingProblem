#include<stdio.h>
#include<stdlib.h>
#include<math.h>
#include<mpi.h>



void advance_field(int nx, int ny, double *f, double *g) {
	int i, j, idx;

	for (i=1; i<nx-1; i++) {
		for (j=1; j<ny-1; j++) {
			idx = i*ny + j;

			f[idx] = 0.49*(g[idx+ny] + g[idx-ny] + g[idx+1] + g[idx-1] - 4*g[idx]) 
			         + 2*g[idx] - f[idx];
		}
	}
}



void exchange_boundary(int nx, int ny, double *f) {
	int i, j;
	int nprocs, myrank;
	MPI_Request req1, req2, req3, req4;
	MPI_Status stat;

	MPI_Comm_size(MPI_COMM_WORLD, &nprocs);
	MPI_Comm_rank(MPI_COMM_WORLD, &myrank);


	if (myrank < nprocs-1) {
		MPI_Isend(&f[(nx-2)*ny], ny, MPI_DOUBLE, myrank+1, 10, MPI_COMM_WORLD, &req1);
		MPI_Irecv(&f[(nx-1)*ny], ny, MPI_DOUBLE, myrank+1, 20, MPI_COMM_WORLD, &req2);
	}

	if (myrank > 0 ) {
		MPI_Isend(&f[ny], ny, MPI_DOUBLE, myrank-1, 20, MPI_COMM_WORLD, &req3);
		MPI_Irecv(&f[0], ny, MPI_DOUBLE, myrank-1, 10, MPI_COMM_WORLD, &req4);
	}

	if (myrank < nprocs-1) {
		MPI_Wait(&req1, &stat);
		MPI_Wait(&req2, &stat);
	}

	if (myrank > 0 ) {
		MPI_Wait(&req3, &stat);
		MPI_Wait(&req4, &stat);
	}
}




int main(int argc, char *argv[]) {
	int tnx=8000, tny=8000;
	int tmax=1000;
	double *f, *g, *ftot;
	int nx, ny;
	int i, j, idx, tstep;
	int nprocs, myrank;


    //-------------------------------------------------------------------------
    // initialize the MPI environment
    //-------------------------------------------------------------------------
	MPI_Init(&argc, &argv);
	MPI_Comm_size(MPI_COMM_WORLD, &nprocs);
	MPI_Comm_rank(MPI_COMM_WORLD, &myrank);
	

	
    //-------------------------------------------------------------------------
    // initialize coefficient and fields
    //-------------------------------------------------------------------------
	nx = tnx/nprocs + 2;
	ny = tny;

	f = (double*)malloc(nx*ny*sizeof(double));
	g = (double*)malloc(nx*ny*sizeof(double));

	for (i=0; i<nx*ny; i++) {
		f[i] = 0;
		g[i] = 0;
	}


    //-------------------------------------------------------------------------
  	// main loop for the time evolution
    //-------------------------------------------------------------------------
	for (tstep=1; tstep<=tmax; tstep++) {
    	//------------------------------------
    	// point source
    	//------------------------------------
		if (nprocs%2 == 0) {
			if (myrank == nprocs/2)
	    		//g[1*ny+(ny/2-1)] = sin(0.02*tstep);
				for (j=0; j<ny; j++)
	    			g[1*ny+j] = sin(0.02*tstep);
		}
		else {
			if (myrank == nprocs/2)
	    		g[(nx/2-1)*ny+(ny/2-1)] = sin(0.02*tstep);
		}

		advance_field(nx, ny, f, g);
		exchange_boundary(nx, ny, f);

		advance_field(nx, ny, g, f);
		exchange_boundary(nx, ny, g);
	}


    //-------------------------------------------------------------------------
  	// gather fields and save as binary files
    //-------------------------------------------------------------------------
	ftot = (double*)malloc(tnx*tny*sizeof(double));
  	MPI_Gather(&f[1], (nx-2)*ny, MPI_DOUBLE, ftot, (nx-2)*ny, MPI_DOUBLE, 0, MPI_COMM_WORLD);

	if (myrank == 0) {
		FILE *fout;
		fout = fopen("field.bin", "wb");
		fwrite(ftot, sizeof(double), tnx*tny, fout);
		fclose(fout);
	}


    //-------------------------------------------------------------------------
    // finalize the MPI environment
    //-------------------------------------------------------------------------
	MPI_Finalize();

	return 0;
}
