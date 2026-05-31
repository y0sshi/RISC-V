#
# RISCOF DUT plugin for this SystemVerilog RV32/RV64 GC core.
#
# The DUT is the RTL itself, exercised in ACT_MODE (rv_soc + rv_unified_mem)
# through iverilog/vvp.  For each architectural test this plugin:
#   1. compiles the .S to an ELF (riscv*-unknown-elf-gcc, native, on PATH)
#   2. objcopy -> Verilog hex (relocated to 0 so rv_unified_mem $readmemh loads at 0x8000_0000)
#   3. extracts begin_signature/end_signature/tohost symbols (objdump)
#   4. iverilog-compiles tb_rv_act.sv with the ACT source list + the addresses
#   5. vvp runs it; tb_rv_act dumps the signature region as 32-bit LE words
#
# Requirements on PATH: riscv64-unknown-elf-gcc/objcopy/objdump, iverilog, vvp.
# (See tests/riscof/README.md.  This mirrors tests/compliance + src/sim sim_act_internal.)
#
import os
import logging
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class rvcore(pluginTemplate):
    __model__ = "rvcore"
    __version__ = "1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        if config is None:
            raise SystemExit("rvcore plugin: missing [rvcore] config section")
        self.num_jobs = str(config.get('jobs', 1))
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        self.target_run = not (config.get('target_run', '1') == '0')
        # Repo root = tests/riscof/rvcore -> ../../..
        self.rv_root = os.path.abspath(os.path.join(self.pluginpath, '..', '..', '..'))
        # Tool prefix (override via [rvcore] riscv_prefix= in config.ini)
        self.prefix = config.get('riscv_prefix', 'riscv64-unknown-elf-')

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.archtest_env = archtest_env
        self.plugin_env = os.path.join(self.pluginpath, 'env')
        self.runner = os.path.join(self.pluginpath, 'run_dut.sh')

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '64' if 64 in ispec['supported_xlen'] else '32'
        self.xlen_def = '-DRV_XLEN_64' if self.xlen == '64' else ''
        self.abi = 'lp64' if self.xlen == '64' else 'ilp32'

    def runTests(self, testList):
        mkpath = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(mkpath):
            os.remove(mkpath)
        make = utils.makeUtil(makefilePath=mkpath)
        make.makeCommand = 'make -k -j' + self.num_jobs
        for testname in testList:
            te = testList[testname]
            test = te['test_path']
            td = te['work_dir']
            elf = os.path.join(td, 'my.elf')
            hexf = os.path.join(td, 'my.hex')
            sig = os.path.join(td, self.name[:-1] + ".signature")
            macros = '-D' + " -D".join(te['macros'])
            # All shell logic lives in run_dut.sh so the Makefile recipe has no
            # shell-level $(...)/$VAR (which make would otherwise expand itself).
            execute = '@cd "{td}"; bash "{run}" "{march}" "{abi}" "{macros}" "{test}" "{elf}" "{hexf}" "{sig}" "{root}" "{penv}" "{aenv}" "{xdef}"'.format(
                td=td, run=self.runner, march=te['isa'].lower(), abi=self.abi,
                macros=macros, test=test, elf=elf, hexf=hexf, sig=sig,
                root=self.rv_root, penv=self.plugin_env, aenv=self.archtest_env,
                xdef=self.xlen_def)
            make.add_target(execute)
        make.execute_all(self.work_dir)
        if not self.target_run:
            raise SystemExit(0)
