import random
import os

# 경로 설정
spike_txt = "tb/spike_input.txt"
inhib_txt = "tb/inhibition_flags.txt"
spike_vh = "tb/spike_rom_init.vh"
inhib_vh = "tb/inhib_rom_init.vh"

NUM_NEURONS = 64
NUM_STEPS = 1024

# Excitatory: 0~31, Inhibitory: 32~63
EXCITATORY_IDX = set(range(32))
INHIBITORY_IDX = set(range(32, 64))

# tb 디렉토리 없으면 생성
os.makedirs("tb", exist_ok=True)

# 1. 텍스트 파일 생성
with open(spike_txt, "w") as spike_f, open(inhib_txt, "w") as inhib_f:
    for _ in range(NUM_STEPS):
        spike_line = ""
        inhib_line = ""
        for i in range(NUM_NEURONS):
            spike = random.choice([0, 1])  # 50% 확률 발화
            spike_line += str(spike)
            inhib_line += "1" if i in INHIBITORY_IDX else "0"
        spike_f.write(spike_line + "\n")
        inhib_f.write(inhib_line + "\n")

print(f"✅ spike_input.txt / inhibition_flags.txt 생성 완료 ({NUM_STEPS}줄)")

# 2. .vh 파일 생성
def convert_to_vh(input_txt_path, output_vh_path, rom_name):
    with open(input_txt_path, "r") as txt_file, open(output_vh_path, "w") as vh_file:
        lines = txt_file.readlines()
        for i, line in enumerate(lines):
            line = line.strip()
            vh_file.write(f'{rom_name}[{i}] = 64\'b{line};\n')
    print(f"✅ {output_vh_path} 생성 완료 ({len(lines)}줄)")

convert_to_vh(spike_txt, spike_vh, "spike_rom")
convert_to_vh(inhib_txt, inhib_vh, "inhib_rom")
