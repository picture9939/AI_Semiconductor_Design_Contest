# ----------------------------------------------------------------
# Verilog ROM Code Generator
# ----------------------------------------------------------------
# 이 스크립트는 spike_input.txt와 inhibition_flags.txt 파일을 읽어
# 합성이 가능한 Verilog case 문을 생성합니다.

# --- 설정 ---
# .txt 파일이 있는 경로를 정확하게 지정해주세요.
# 현재 위치(synthesis)에서 상위 폴더(프로젝트 루트)의 simulation 폴더를 가리킵니다.
SPIKE_FILE = '../simulation/spike_input.txt'
INHIB_FILE = '../simulation/inhibition_flags.txt'
NEURON_WIDTH = 64
# ------------

def generate_verilog_rom(txt_file, signal_name, width):
    """지정된 .txt 파일로부터 Verilog case 문을 생성하는 함수"""
    verilog_code = []
    try:
        with open(txt_file, 'r') as f:
            for i, line in enumerate(f):
                line = line.strip()
                if line: # 빈 줄이 아니면
                    verilog_code.append(f"        {i}: {signal_name} = {width}'b{line};")

        # case 문 완성
        full_code = f"always @(*) begin\n"
        full_code += f"    case (time_step)\n"
        full_code += "\n".join(verilog_code)
        full_code += f"\n        default: {signal_name} = {width}'b0;\n"
        full_code += f"    endcase\n"
        full_code += f"end"
        return full_code

    except FileNotFoundError:
        return f"// ***** ERROR: '{txt_file}' 파일을 찾을 수 없습니다. 경로를 확인하세요. *****"

# --- 스크립트 실행 ---
print("="*60)
print("spike_pattern ROM을 위한 Verilog 코드를 생성합니다.")
print("="*60)
print(generate_verilog_rom(SPIKE_FILE, 'spike_pattern', NEURON_WIDTH))
print("\n")
print("="*60)
print("inhib_pattern ROM을 위한 Verilog 코드를 생성합니다.")
print("="*60)
print(generate_verilog_rom(INHIB_FILE, 'inhib_pattern', NEURON_WIDTH))
