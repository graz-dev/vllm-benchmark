#!/bin/bash
#
hyperfine -r 1 \
	--show-output \
	-L mu 0.96 \
	-L mt 8192,512,1024 \
	-L ms 96 \
	-S bash 'VLLM_GPU_MEMORY_UTIL={mu} VLLM_MAX_TOKENS={mt} VLLM_MAX_SEQS={ms} BENCH_FILE=01-job-sweep.yaml ./run.sh'
