import random

spike_file = "tb/spike_input.txt"
inhib_flag_file = "tb/inhibition_flags.txt"

NUM_NEURONS = 64
NUM_STEPS = 1024

# Excitatory: 0~31, Inhibitory: 32~63
EXCITATORY_IDX = set(range(32))
INHIBITORY_IDX = set(range(32, 64))

with open(spike_file, "w") as spike_f, open(inhib_flag_file, "w") as inhib_f:
    for _ in range(NUM_STEPS):
        spike_line = ""
        inhib_line = ""

        for i in range(NUM_NEURONS):
            spike = random.choice([0, 1])  # 50% 확률로 발화

            # spike 기록
            spike_line += str(spike)

            # inhibition flag 기록 (1 = inhibitory 뉴런, 0 = excitatory)
            inhib_line += "1" if i in INHIBITORY_IDX else "0"

        spike_f.write(spike_line + "\n")
        inhib_f.write(inhib_line + "\n")

print(f"✅ 랜덤 spike_input.txt + inhibition_flags.txt 생성 완료 ({NUM_STEPS}줄)")
