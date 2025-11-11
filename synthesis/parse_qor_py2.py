# -*- coding: utf-8 -*-

def parse_qor_report(file_path):
    try:
        f = open(file_path, 'r')
        lines = f.readlines()
        f.close()
    except:
        print("파일을 열 수 없습니다: " + file_path)
        return

    info = {
        'Cell Area': None,
        'Total Area': None,
        'Sequential Instance Count': None,
        'Combinational Instance Count': None,
        'Hierarchical Instance Count': None,
        'Max Fanout': None,
        'Min Fanout': None,
        'Average Fanout': None,
        'Runtime': None,
        'Elapsed Runtime': None,
        'Memory Usage': None
    }

    for line in lines:
        if 'Cell Area' in line and 'Total' not in line:
            info['Cell Area'] = line.strip().split()[-1]
        elif 'Total Area' in line:
            info['Total Area'] = line.strip().split()[-1]
        elif 'Sequential Instance Count' in line:
            info['Sequential Instance Count'] = line.strip().split()[-1]
        elif 'Combinational Instance Count' in line:
            info['Combinational Instance Count'] = line.strip().split()[-1]
        elif 'Hierarchical Instance Count' in line:
            info['Hierarchical Instance Count'] = line.strip().split()[-1]
        elif 'Max Fanout' in line:
            parts = line.strip().split()
            info['Max Fanout'] = parts[-2] + ' ' + parts[-1]
        elif 'Min Fanout' in line:
            parts = line.strip().split()
            info['Min Fanout'] = parts[-2] + ' ' + parts[-1]
        elif 'Average Fanout' in line:
            info['Average Fanout'] = line.strip().split()[-1]
        elif 'Runtime' in line and 'Elapsed' not in line:
            info['Runtime'] = line.strip().split()[-2] + ' seconds'
        elif 'Elapsed Runtime' in line:
            info['Elapsed Runtime'] = line.strip().split()[-2] + ' seconds'
        elif 'Genus peak memory usage' in line:
            info['Memory Usage'] = line.strip().split()[-1] + ' MB'

    print("\n?? Genus QOR Report Summary")
    print("-" * 40)
    keys = [
        'Cell Area', 'Total Area',
        'Sequential Instance Count', 'Combinational Instance Count', 'Hierarchical Instance Count',
        'Max Fanout', 'Min Fanout', 'Average Fanout',
        'Runtime', 'Elapsed Runtime', 'Memory Usage'
    ]
    for k in keys:
        val = info[k] if info[k] else 'N/A'
        print("%-30s: %s" % (k, val))

# 실행
if __name__ == "__main__":
    parse_qor_report("reports/qor.rpt")
