"""Reproducible F10/F13/F15/F16/F20/F22/F26 regression: Python stdlib + Icarus Verilog, Windows/WSL.

Never accept process exit code alone: legacy TBs can print FAIL and exit zero.
All generated files remain under kltn. No tool installation is performed.
"""
import argparse
import csv
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
RTL=ROOT/'rtl/core_if'
TB=ROOT/'tb/core_if'
BUILD=ROOT/'sim/build/f10'


def main():
    global BUILD
    parser=argparse.ArgumentParser()
    parser.add_argument('--checkpoint', choices=('f10','f13','f15','f16','f20','f22','f26'), default='f26')
    parser.add_argument('--report-dir',type=Path)
    args=parser.parse_args()
    checkpoint=args.checkpoint
    BUILD=ROOT/'sim/build'/checkpoint
    default_report={'f10':'f10_20260920','f13':'f13_20260926','f15':'f15_20260927','f16':'f16_20261001',
                    'f20':'f20_20261001','f22':'f22_20261003','f26':'f26_20261005'}[checkpoint]
    report=(args.report_dir or ROOT/'reports'/default_report).resolve()
    report.mkdir(parents=True,exist_ok=True); BUILD.mkdir(parents=True,exist_ok=True)
    tools={name:shutil.which(name) for name in ('iverilog','vvp')}
    if not all(tools.values()): raise RuntimeError('Need iverilog and vvp in PATH. WSL: sudo apt install iverilog')
    checks=[]
    summary={'status':'RUNNING','utc':datetime.now(timezone.utc).isoformat(),
             'platform':platform.platform(),'python':sys.version,'tools':tools,'checks':checks}
    summary_path=report/'summary.json'
    summary_path.write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')

    def command(name,argv,marker=None,timeout=120):
        result=subprocess.run([str(x) for x in argv],cwd=ROOT,capture_output=True,text=True,timeout=timeout)
        output=result.stdout+result.stderr
        (report/(name+'.log')).write_text(output,encoding='utf-8')
        if result.returncode or re.search(r'\[FAIL\]|TEST_FAIL|FATAL:|ERROR:',output):
            raise RuntimeError(f'{name} failed:\n{output}')
        if marker and marker not in output: raise RuntimeError(f'{name}: missing PASS marker\n{output}')
        if marker:
            checks.append({'name':name,'status':'PASS','marker':marker})
            print(f'{name}: PASS',flush=True)
        return output

    def compile_tb(name,top,sources,delayed=False):
        binary=BUILD/name
        args=[tools['iverilog'],'-g2012','-Wall','-Wno-timescale','-s',top,'-o',binary]
        if delayed: args.append('-DDELAYED_MEMORY')
        output=command(name+'.compile',args+sources+[TB/(top+'.v')])
        if 'warning:' in output.lower(): raise RuntimeError(f'{name}: compile warnings must be reviewed:\n{output}')
        return binary

    try:
        versions=command('tool_versions',[tools['iverilog'],'-V'])
        summary['iverilog_version']=versions.splitlines()[0]
        command('gen_addsub',[sys.executable,ROOT/'scripts/gen_fp32_addsub_vectors.py','--output',BUILD/'addsub.txt'])
        command('gen_programs',[sys.executable,ROOT/'scripts/gen_f10_programs.py','--output',BUILD/'programs']+
                ({'f10':[], 'f13':['--include-compare'], 'f15':['--include-minmax'],
                  'f16':['--include-mul'], 'f20':['--include-convert'],
                  'f22':['--include-divsqrt'], 'f26':['--include-fma']}[checkpoint]))
        if checkpoint in ('f13','f15','f16','f20','f22','f26'):
            command('gen_compare',[sys.executable,ROOT/'scripts/gen_fp32_compare_vectors.py','--output',BUILD/'compare.txt'])
        if checkpoint in ('f15','f16','f20','f22','f26'):
            command('gen_minmax',[sys.executable,ROOT/'scripts/gen_fp32_minmax_vectors.py','--output',BUILD/'minmax.txt'])
        if checkpoint in ('f16','f20','f22','f26'):
            command('gen_mul',[sys.executable,ROOT/'scripts/gen_fp32_mul_vectors.py','--output',BUILD/'mul.txt'])
        if checkpoint in ('f20','f22','f26'):
            command('gen_convert',[sys.executable,ROOT/'scripts/gen_fp32_convert_vectors.py','--output',BUILD/'convert.txt'])
        if checkpoint in ('f22','f26'):
            command('gen_divsqrt',[sys.executable,ROOT/'scripts/gen_fp32_divsqrt_vectors.py','--output',BUILD/'divsqrt.txt'])
        if checkpoint=='f26':
            command('gen_fma',[sys.executable,ROOT/'scripts/gen_fp32_fma_vectors.py','--output',BUILD/'fma.txt'])
        all_rtl=sorted(RTL.glob('*.v'))
        cases=[
            ('register_file','tb_register_file',['register_file.v'],'REGISTER_FILE_TEST_PASS'),
            ('fp_register_file','tb_fp_register_file',['fp_register_file.v'],'FP_REGISTER_FILE_TEST_PASS'),
            ('alu','tb_alu',['alu.v'],'ALU_TEST_PASS'),
            ('fp_mem_decode','tb_fp_mem_decode',['type_decoder.v','control_decoder.v','control_unit.v'],'FP_MEM_DECODE_TEST_PASS'),
            ('fp32_addsub','tb_fp32_addsub',['fp32_addsub.v'],'FP32_ADDSUB_TEST_PASS'),
            ('fp_decode','tb_fp_decode',['fp_decode.v'],'FP_DECODE_TEST_PASS'),
            ('fp_misc','tb_fp_misc',['fp_misc.v'],'FP_MISC_TEST_PASS'),
            ('fp_csr','tb_fp_csr',['fp_csr.v'],'FP_CSR_TEST_PASS'),
        ]
        if checkpoint in ('f13','f15','f16','f20','f22','f26'):
            cases.append(('fp32_compare','tb_fp32_compare',['fp32_compare.v'],'FP32_COMPARE_TEST_PASS'))
        if checkpoint in ('f15','f16','f20','f22','f26'):
            cases.append(('fp32_minmax','tb_fp32_minmax',['fp32_compare.v'],'FP32_MINMAX_TEST_PASS'))
        if checkpoint in ('f16','f20','f22','f26'):
            cases.append(('fp32_mul','tb_fp32_mul',['fp32_mul.v'],'FP32_MUL_TEST_PASS'))
        if checkpoint in ('f20','f22','f26'):
            cases.append(('fp32_convert','tb_fp32_convert',['fp32_convert.v'],'FP32_CONVERT_TEST_PASS'))
        if checkpoint in ('f22','f26'):
            cases.append(('fp32_divsqrt','tb_fp32_divsqrt',['fp32_divsqrt.v'],'FP32_DIVSQRT_TEST_PASS'))
        if checkpoint=='f26':
            cases.append(('fp32_fma','tb_fp32_fma',['fp32_fma.v'],'FP32_FMA_TEST_PASS'))
        for name,top,sources,marker in cases:
            binary=compile_tb(name,top,[RTL/x for x in sources])
            argv=[tools['vvp'],binary]
            if name=='fp32_addsub': argv.append('+vectors='+str(BUILD/'addsub.txt'))
            if name=='fp32_compare': argv.append('+vectors='+str(BUILD/'compare.txt'))
            if name=='fp32_minmax': argv.append('+vectors='+str(BUILD/'minmax.txt'))
            if name=='fp32_mul': argv.append('+vectors='+str(BUILD/'mul.txt'))
            if name=='fp32_convert': argv.append('+vectors='+str(BUILD/'convert.txt'))
            if name=='fp32_divsqrt': argv.append('+vectors='+str(BUILD/'divsqrt.txt'))
            if name=='fp32_fma': argv.append('+vectors='+str(BUILD/'fma.txt'))
            command(name+'.run',argv,marker,timeout=600 if name in ('fp32_divsqrt','fp32_fma') else 120)
        manifest=json.loads((BUILD/'programs/manifest.json').read_text())
        cycle_rows=[]
        for delayed in (False,True):
            suffix='_delayed' if delayed else ''
            binary=compile_tb('fp_mem_e2e'+suffix,'tb_fp_mem_e2e',all_rtl,delayed)
            command('fp_mem_e2e'+suffix+'.run',[tools['vvp'],binary],
                    'FP_MEM_E2E_DELAYED_TEST_PASS' if delayed else 'FP_MEM_E2E_TEST_PASS')
            binary=compile_tb('f10_e2e'+suffix,'tb_f10_e2e',all_rtl+[TB/'tb_fp_mem_e2e.v'],delayed)
            for case in manifest['cases']:
                name=case['name']+suffix
                argv=[tools['vvp'],binary,'+case='+str(BUILD/'programs'/(case['name']+'.txt'))]
                if case['name']=='demo_f10':
                    argv+=['+vcd='+str(report/('demo_f10'+suffix+'.vcd')),
                           '+trace_csv='+str(report/('demo_f10'+suffix+'.csv')),'+reset_test']
                output=command(name+'.run',argv,'F10_E2E_TEST_PASS')
                if case['name']=='demo_f10' and 'F10_RESET_BUSY_TEST_PASS' not in output:
                    raise RuntimeError('Missing reset-under-load check')
                match=re.search(r'retired=(\d+) requests=(\d+) cycles=(\d+)',output)
                if not match: raise RuntimeError('Missing CPU measurements')
                retired,requests,cycles=map(int,match.groups())
                if (retired,requests)!=(case['retired'],case['memory_requests']):
                    raise RuntimeError('Wrong program/counts')
                cycle_rows.append([case['name'],'delayed' if delayed else 'normal',retired,requests,cycles])
        with (report/'program_cycles.csv').open('w',newline='',encoding='utf-8') as out:
            writer=csv.writer(out,lineterminator='\n'); writer.writerow(['program','memory','retired_instructions','memory_requests','cycles_from_release_to_last_retire']); writer.writerows(cycle_rows)
        summary.update(status='PASS',test_count=len(checks),programs_per_memory=len(manifest['cases']),
                       retirement_checks=2*sum(c['retired'] for c in manifest['cases']),
                       instruction_executions_per_memory=manifest['coverage'],
                       reset_busy_checks=2,
                       rtl_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in all_rtl})
        (report/'instruction_status.csv').write_text(
            'instruction,status,executions_normal,executions_delayed\n'+''.join(
                f'{ins},PASS,{count},{count}\n' for ins,count in sorted(manifest['coverage'].items())),encoding='utf-8')
        for filename in ('demo_f10.hex','demo_f10_data.hex','manifest.json'):
            shutil.copyfile(BUILD/'programs'/filename,report/filename)
        instruction_count={'f10':10,'f13':13,'f15':15,'f16':16,'f20':20,'f22':22,'f26':26}[checkpoint]
        summary.update(checkpoint=checkpoint,implemented_f_instructions=instruction_count)
        print(f'CORE_IF_{checkpoint.upper()}_TESTS_PASS ({len(checks)}/{len(checks)}); F instructions={instruction_count}/26; CSR forms=6',flush=True)
        print(f'Report: {report}',flush=True)
    except Exception as exc:
        summary.update(status='FAIL',error=str(exc)); raise
    finally:
        summary_path.write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__': main()
