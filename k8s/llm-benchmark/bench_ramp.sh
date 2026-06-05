#!/bin/bash
#
#
BENCH_FILE_TEMPL=01-job-concurrent.yaml.templ
BENCH_FILE=01-job-concurrent.yaml
DURATION=180

sed -e "s/RATE/10/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/20/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/30/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/40/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/50/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/60/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/70/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/80/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/90/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s

sed -e "s/RATE/100/" -e "s/DURATION/$DURATION/" $BENCH_FILE_TEMPL > $BENCH_FILE
kubectl delete -f 01-job-sweep.yaml ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s
