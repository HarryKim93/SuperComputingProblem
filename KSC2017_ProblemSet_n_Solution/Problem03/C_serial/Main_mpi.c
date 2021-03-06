#include "Boyer-Moore.h"
#include <unistd.h>
#include <string.h>
#include <mpi.h>

#define MAX_STRING_LENGTH 256

int64_t get_filesize(char *target_path)
{
	int64_t buffsize;
	int32_t fd = open(target_path, O_RDONLY);
	if(fd == -1)
		return -1;
	struct stat fd_stat;
	fstat(fd, &fd_stat);
	buffsize = fd_stat.st_size;
	return buffsize;
}

char* read_targetfile(char *target, int64_t target_length, char *target_path)
{
	FILE *fp = fopen((char*)target_path, "r");
	*target = '\0';

	if (fp != NULL) {
		size_t newLen = fread(target, sizeof(char), target_length, fp);
		if (newLen == 0) {
			printf("\nError: Cannot read target file [ %s ]\n", target_path);
			MPI_Finalize();
			exit(1);
		} else {
			target[newLen] = '\0'; /* Just to be safe. */
		}
	}
	fclose(fp);
	return target;
}

int32_t main(int32_t argc, char *argv[])
{
	int32_t rankID = 0, nRanks = 1;
	char rankName[MAX_STRING_LENGTH];
	gethostname(rankName, MAX_STRING_LENGTH);
	MPI_Init(&argc, &argv);
	MPI_Comm_rank(MPI_COMM_WORLD, &rankID);
	MPI_Comm_size(MPI_COMM_WORLD, &nRanks);

	char *target_path = argv[1], *target = NULL;
	int64_t target_length = 0;
	target_length = get_filesize(target_path);
	if(target_length < 0)
	{
		printf("\nError: Cannot read target file [ %s ]\n", target_path);
		MPI_Finalize();
		exit(-1);
	}
	if(rankID == 0)
	{
		printf("--------------------------------------------------\n");
		printf("- Read target: [ %s ]\n", target_path);
		target = (char*)malloc(sizeof(char)*target_length);
		double read_time = 0;
		read_time -= MPI_Wtime();
		read_targetfile(target, target_length, target_path);
		read_time += MPI_Wtime();
		printf("- Target length: %ld (read time: %lf secs)\n", target_length, read_time);
		printf("--------------------------------------------------\n");
	}

	char *pattern = argv[2];
	int64_t pattern_length = 0;
	if(pattern == NULL)
	{
		printf("\nError: Cannot read pattern [ %s ]\n", pattern);
		free(target);
		MPI_Finalize();
		exit(-1);
	}
	pattern_length = strlen(pattern);
	if(rankID == 0)
	{
		printf("- Pattern: [ %s ]\n", pattern);
		printf("- Pattern length: %ld\n", pattern_length);
		printf("--------------------------------------------------\n");
	}
	int32_t* BCS = (int32_t*)malloc(ALPHABET_LEN * sizeof(int32_t));
	int32_t* GSS = (int32_t*)malloc(pattern_length * sizeof(int32_t));;
	make_BCS(BCS, pattern, pattern_length);
	make_GSS(GSS, pattern, pattern_length);

	int64_t found_count = 0;
	double search_time = 0;
	if(rankID == 0)
	{
		search_time -= MPI_Wtime();
	}
// DO NOT EDIT UPPER CODE //
//==============================================================================================================//

	int64_t mpi_found_count = 0;
	char* chunk = NULL;
	if(argv[3] == NULL)
	{
		printf("\nError: Check chunk size [ %s ]\n", argv[3]);
		free(target);
		free(BCS);
		free(GSS);
		MPI_Finalize();
		exit(-1);
	}
	/**
	* chunk의 크기는 20(주어진 코어의 개수)
	* chuck의 크기를 이용하여 각 chunk에 얼만큼의 text가 들어가야 하는지 구한다.
	* 몫을 통해서 각 job 공간을 만든 다음에, 남은 text를 remainder를 이용하여 분할한다.
	* 이렇게 하면 각 랭크마다 일을 할당하는 것이 아니라, 일이 끝난 노드에서 알아서 남은 chunk를 가져간다.
	* rank-0는 일을 하지않는다는 점에 유의한다.
	* 결과는 reduce로 모은다.
	*/
	int64_t nChunksPerRank = atoi(argv[3]);
	int64_t nTotalChunks = (nRanks-1) * nChunksPerRank; // rank-0는 일을하지 않는다는 점에 유의한다.
	int64_t overlap_length = (pattern_length - 1) * (nTotalChunks - 1); // 첫번째 chunk는 overlap이 필요없음. 최대 겹치는게 pattern_length - 1 + 첫번째 idx에있는 문자임.
	int64_t quotient = (target_length + overlap_length) / nTotalChunks; 
	int64_t remainder = (target_length + overlap_length) - (quotient * nTotalChunks);

	int64_t chunkID = 0;
	int64_t* chunk_length = (int64_t*)malloc((nTotalChunks+1)*sizeof(int64_t)); // 널문자까지 합쳐서 +1 하는것 잊지 말자.
	int64_t* chunk_start_idx = (int64_t*)malloc((nTotalChunks+1)*sizeof(int64_t)); 
	int64_t i;
	for(i=0; i<nTotalChunks; i++)
		chunk_length[i] = quotient;
	for(i=0; i<remainder; i++)
		chunk_length[i] += 1;
	chunk_start_idx[0] = 0;
	for(i=1; i<nTotalChunks; i++)
		chunk_start_idx[i] = chunk_start_idx[i-1] + chunk_length[i-1] - (pattern_length-1); // overlap length를 신경쓴것이다.

	chunk_start_idx[nTotalChunks] = 0;
	chunk_length[nTotalChunks] = 0;

	MPI_Request MPI_req[2];
	MPI_Status MPI_stat[2];
	int32_t MPI_tag = 0;
	int32_t request_rankID = -1;
	if(rankID == 0)
	{
		int64_t nFinishRanks = 0;
		while(nFinishRanks < nRanks-1)
		{
			MPI_Recv(&request_rankID, 1, MPI_INT32_T, MPI_ANY_SOURCE, MPI_tag, MPI_COMM_WORLD, &MPI_stat[0]);
			MPI_Isend(&target[chunk_start_idx[chunkID]], chunk_length[chunkID], MPI_CHAR, request_rankID, chunkID, MPI_COMM_WORLD, &MPI_req[1]);
			if(chunkID < nTotalChunks)
				chunkID++;
			else
				nFinishRanks++;
		}
	}
	else
	{
		chunk = (char *)malloc(chunk_length[0] * sizeof(char));
		int64_t chunk_found_count = 0;
		int64_t call_count = 0;
		while(chunkID < nTotalChunks)
		{
			MPI_Isend(&rankID, 1, MPI_INT32_T, 0, MPI_tag, MPI_COMM_WORLD, &MPI_req[0]);
			MPI_Recv(chunk, chunk_length[0], MPI_CHAR, 0, MPI_ANY_TAG, MPI_COMM_WORLD, &MPI_stat[1]);
			chunkID = MPI_stat[1].MPI_TAG;
			if(chunkID < nTotalChunks)
			{
				chunk_found_count = do_search(chunk, target_length, 0, chunk_length[chunkID], pattern, pattern_length, BCS, GSS);
				if(found_count < 0)
				{
					free(chunk);
					free(BCS);
					free(GSS);
					free(chunk_length);
					free(chunk_start_idx);
					MPI_Finalize();
					exit(-1);
				}
				mpi_found_count += chunk_found_count;
				call_count++;
			}
		}
		printf("- [%02d: %s] call_count: %ld\n", rankID, rankName, call_count);
	}
	MPI_Reduce(&mpi_found_count, &found_count, 1, MPI_INT64_T, MPI_SUM, 0, MPI_COMM_WORLD);
	free(chunk);
	free(chunk_length);
	free(chunk_start_idx);

//==============================================================================================================//
// DO NOT EDIT LOWER CODE //
	if(rankID == 0)
	{
		search_time += MPI_Wtime();
		printf("- Found_count: %ld\n", found_count);
		printf("--------------------------------------------------\n");
		printf("- Time: %lf secs\n", search_time);
		printf("--------------------------------------------------\n");
	}

	free(target);
	free(BCS);
	free(GSS);
	MPI_Finalize();

	return 0;
}