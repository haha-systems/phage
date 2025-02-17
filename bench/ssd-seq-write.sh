#!/bin/bash
fio --name=phage-test --ioengine=io_uring --direct=1 \
                                           --rw=write --bs=1M --numjobs=6 --iodepth=64 \
                                           --time_based --runtime=60 --group_reporting --size=1M
