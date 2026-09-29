#
# RISCOF reference plugin: Spike (riscv-isa-sim) as the golden model.
#
# Compiles each architectural test with riscv*-unknown-elf-gcc and runs it on
# Spike with +signature, producing the reference signature RISCOF diffs against
# the DUT signature.  Requires `spike` and the toolchain on PATH (see README;
# build Spike via tests/riscof/spike/Dockerfile or natively).
#
import os
import logging
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class spike(pluginTemplate):
    __model__ = "spike"
    __version__ = "1.1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        if config is None:
            raise SystemExit("spike plugin: missing [spike] config section")
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.num_jobs = str(config.get('jobs', 1))
        self.spike_exe = os.path.join(config.get('PATH', ''), 'spike')
        self.prefix = config.get('riscv_prefix', 'riscv64-unknown-elf-')
        # Optional ISA/platform yamls if the reference exposes them
        self.isa_spec = os.path.abspath(config['ispec']) if 'ispec' in config else ''
        self.platform_spec = os.path.abspath(config['pspec']) if 'pspec' in config else ''

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.compile_cmd = (
            self.prefix + 'gcc -march={0} -mabi={1} -mcmodel=medany '
            '-static -nostdlib -nostartfiles -fno-common '
            '-T "' + os.path.join(self.pluginpath, 'env', 'link.ld') + '" '
            '-I "' + os.path.join(self.pluginpath, 'env') + '" '
            '-I "' + archtest_env + '" {2} {3} -o {4}'
        )

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '64' if 64 in ispec['supported_xlen'] else '32'
        self.abi = 'lp64' if self.xlen == '64' else 'ilp32'
        # Build the Spike --isa string from the ISA yaml extension set
        ext = ispec['ISA']
        self.isa = 'rv' + self.xlen + ''.join(
            c.lower() for c in 'IMAFDC' if c in ext)

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
            elf = os.path.join(td, 'ref.elf')
            sig = os.path.join(td, self.name[:-1] + ".signature")
            macros = ' -D' + " -D".join(te['macros'])
            cc = self.compile_cmd.format(te['isa'].lower(), self.abi, macros, test, elf)
            sim = '%s --isa=%s +signature="%s" +signature-granularity=4 "%s"' % (
                self.spike_exe, self.isa, sig, elf)
            make.add_target('@cd "%s"; %s && %s' % (td, cc, sim))
        make.execute_all(self.work_dir)
