import os
import subprocess
import traceback
import util

MODULE_NAME = __name__
MODULE_DESCRIPTION = '''Run analysis of code built with a command like:
xcodebuild [options]

Analysis examples:
infer -- xcodebuild -target HelloWorldApp -sdk iphonesimulator
infer -- xcodebuild -workspace HelloWorld.xcworkspace -scheme HelloWorld'''

SCRIPT_DIR = os.path.dirname(__file__)
INFER_ROOT = os.path.join(SCRIPT_DIR, '..', '..', '..')
FCP_ROOT = os.path.join(INFER_ROOT, '..', 'facebook-clang-plugin')
CLANG_WRAPPER = os.path.join(
    SCRIPT_DIR, 'clang',
)
CLANGPLUSPLUS_WRAPPER = os.path.join(
    SCRIPT_DIR, 'clang++',
)


def gen_instance(*args):
    return XcodebuildCapture(*args)

# This creates an empty argparser for the module, which provides only
# description/usage information and no arguments.
create_argparser = util.base_argparser(MODULE_DESCRIPTION, MODULE_NAME)


class XcodebuildCapture:
    def __init__(self, args, cmd):
        self.args = args
        self.cmd = cmd

    def capture(self):
        env_vars = dict(os.environ)

        # get the path to 'true' using xcrun
        true_path = subprocess.check_output(['xcrun', '--find', 'true']).strip()

        # these settings will instruct xcodebuild on which clang to use
        # and to not run any linking
        self.cmd += ['LD={true_path}'.format(true_path=true_path)]
        self.cmd += ['LDPLUSPLUS={true_path}'.format(true_path=true_path)]
        self.cmd += ['CC={wrapper}'.format(wrapper=CLANG_WRAPPER)]
        self.cmd += ['CPLUSPLUS={wrapper}'.format(wrapper=CLANGPLUSPLUS_WRAPPER)]
        self.cmd += ['LIPO={true_path}'.format(true_path=true_path)]

        env_vars['INFER_RESULTS_DIR'] = self.args.infer_out

        # fix the GenerateDSYMFile error
        self.cmd += ["DEBUG_INFORMATION_FORMAT='dwarf'"]

        try:
            subprocess.check_call(self.cmd, env=env_vars)
            return os.EX_OK
        except subprocess.CalledProcessError as exc:
            if self.args.debug:
                traceback.print_exc()
            print(exc.output)
            return exc.returncode
