#!/usr/bin/env python

# Copyright (c) 2013- Facebook.
# All rights reserved.

import argparse
import os
import subprocess
import inferlib


def create_inferJ_command(args, javac_arguments):
    infer_args = ['-o', args.infer_out]
    if args.debug:
        infer_args.append('--debug')
    infer_args += ['--analyzer', 'capture']

    return inferlib.Infer(inferlib.inferJ_parser.parse_args(infer_args),
                          inferlib.get_javac_args(['javac'] + javac_arguments))


def get_build_output(build_cmd):
    #  TODO make it return generator to be able to handle large builds
    proc = subprocess.Popen(build_cmd, stdout=subprocess.PIPE)
    (verbose_out_chars, _) = proc.communicate()
    return verbose_out_chars.split('\n')


def run_commands(cmds):
    #  TODO call it in parallel
    if len(cmds) == 0:
        return os.EX_NOINPUT
    for cmd in cmds:
        if not cmd.start():
            return os.EX_SOFTWARE
    return os.EX_OK


def base_argparser(description, module_name):
    def _func(group_name=module_name):
        """This creates an empty argparser for the module, which provides only
        description/usage information and no arguments."""
        parser = argparse.ArgumentParser(add_help=False)
        group = parser.add_argument_group(
            "{grp} module".format(grp=group_name),
            description=description,
        )
        return parser
    return _func


def clang_frontend_argparser(description, module_name):
    def _func(group_name=module_name):
        """This creates an argparser for all the modules that require
        clang for their capture phase, thus InferClang and clang wrappers"""
        parser = argparse.ArgumentParser(add_help=False)
        group = parser.add_argument_group(
            "{grp} module".format(grp=group_name),
            description=description,
        )
        group.add_argument(
            '-hd', '--headers',
            action='store_true',
            help='Analyze code in header files',
        )
        group.add_argument(
            '--models_mode',
            action='store_true',
            dest='models_mode',
            help='Mode for computing the models',
        )
        group.add_argument(
            '--no_failures_allowed',
            action='store_true',
            dest='no_failures_allowed',
            help='Fail if at least one of the translations fails',
        )
        group.add_argument(
            '-tm', '--testing_mode',
            dest='testing_mode',
            action='store_true',
            help='Testing mode for the translation: Do not translate libraries'
                 ' (including enums)')
        group.add_argument(
            '-fs', '--frontend-stats',
            dest='frontend_stats',
            action='store_true',
            help='Output statistics about the capture phase to *.o.astlog')
        group.add_argument(
            '-fd', '--frontend-debug',
            dest='frontend_debug',
            action='store_true',
            help='Output debugging information to *.o.astlog during capture')
        return parser
    return _func


def get_clang_frontend_envvars(args):
    """Return the environment variables that configure the clang wrapper, e.g.
    to emit debug information if needed, and the invocation of the Infer
    frontend for Clang, InferClang, e.g. to analyze headers, emit stats, etc"""
    env_vars = {}
    frontend_args = []

    env_vars['INFER_RESULTS_DIR'] = args.infer_out
    if args.headers:
        frontend_args.append('-headers')
    if args.models_mode:
        frontend_args.append('-models_mode')
    if args.project_root:
        frontend_args += ['-project_root', args.project_root]
    if args.testing_mode:
        frontend_args.append('-testing_mode')
    if args.frontend_debug:
        frontend_args += ['-debug']
        env_vars['FCP_DEBUG_MODE'] = '1'
    if args.frontend_stats:
        frontend_args += ['-stats']
        env_vars['FCP_DEBUG_MODE'] = '1'
    if args.no_failures_allowed:
        env_vars['FCP_REPORT_FRONTEND_FAILURE'] = '1'

    # export an env variable with all the arguments to pass to InferClang
    env_vars['FCP_INFER_FRONTEND_ARGS'] = ' '.join(frontend_args)
    return env_vars
