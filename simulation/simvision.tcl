database -open waves -shm
probe -create sim:/tb_02_crossbar/* -depth all -database waves
probe -create sim:/tb_02_crossbar/dut/* -depth all -database waves
run 1 ms
exit
