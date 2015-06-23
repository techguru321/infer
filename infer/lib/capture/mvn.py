#
# Copyright (c) 2013- Facebook.  All rights reserved.
#

import os
import logging
import re
import util

MODULE_NAME = __name__
MODULE_DESCRIPTION = '''Run analysis of code built with a command like:
mvn [options] [task]

Analysis examples:
infer -- mvn build'''

def gen_instance(*args):
    return MavenCapture(*args)

# This creates an empty argparser for the module, which provides only
# description/usage information and no arguments.
create_argparser = util.base_argparser(MODULE_DESCRIPTION, MODULE_NAME)


class MavenCapture:
    def __init__(self, args, cmd):
        self.args = args
        logging.info(util.run_cmd_ignore_fail(['mvn', '-version']))
        # TODO: make the extraction of targets smarter
        self.build_cmd = ['mvn', '-X'] + cmd[1:]

    def get_inferJ_commands(self, verbose_output):
        file_pattern = r'\[DEBUG\] Stale source detected: ([^ ]*\.java)'
        options_pattern = '[DEBUG] Command line options:'

        files_to_compile = []
        calls = []
        options_next = False
        for line in verbose_output:
            if options_next:
                #  line has format [Debug] <space separated options>
                javac_args = line.split(' ')[1:] + files_to_compile
                capture = util.create_inferJ_command(self.args, javac_args)
                calls.append(capture)
                options_next = False
                files_to_compile = []

            elif options_pattern in line:
                #  Next line will have javac options to run
                options_next = True

            else:
                found = re.match(file_pattern, line)
                if found:
                    files_to_compile.append(found.group(1))

        return calls

    def capture(self):
        cmds = self.get_inferJ_commands(util.get_build_output(self.build_cmd))
        return util.run_commands(cmds)
