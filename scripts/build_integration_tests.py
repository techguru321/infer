#!/usr/bin/env python2.7
# Copyright (c) 2015 - present Facebook, Inc.
# All rights reserved.
#
# This source code is licensed under the BSD style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS_DIRECTORY = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0,
                os.path.join(SCRIPTS_DIRECTORY,
                             os.pardir, 'infer', 'lib', 'python'))

from inferlib import issues, utils


CURRENT_DIR = os.getcwd()
REPORT_JSON = 'report.json'

INFER_EXECUTABLE = 'infer'

RECORD_ENV = 'INFER_RECORD_INTEGRATION_TESTS'

REPORT_FIELDS = [
    issues.JSON_INDEX_FILENAME,
    issues.JSON_INDEX_PROCEDURE,
    issues.JSON_INDEX_TYPE,
]


def should_record_tests():
    return RECORD_ENV in os.environ and os.environ[RECORD_ENV] == '1'


def quote(s):
    return '\"%s\"' % s


def string_of_error(e):
    line = ''
    if issues.JSON_INDEX_LINE in e:
        line = ' on line %s ' % e[issues.JSON_INDEX_LINE]
    msg = '%s in file %s, procedure %s%s' % (
        e[issues.JSON_INDEX_TYPE],
        quote(e[issues.JSON_INDEX_FILENAME]),
        quote(e[issues.JSON_INDEX_PROCEDURE]),
        line,
    )
    return msg


def save_report(reports, filename):
    # sorting to avoid spurious differences between two lists of reports
    reports.sort()

    def filter_report(report):
        return dict((k, v) for (k, v) in report.items() if k in REPORT_FIELDS)

    def should_report(report):
        return len(report) > 0

    filtered = filter(should_report, map(filter_report, reports))
    utils.dump_json_to_path(filtered, filename,
                            separators=(',', ': '), sort_keys=True)


def run_analysis(root, clean_cmd, build_cmd, analyzer):
    os.chdir(root)

    subprocess.check_call(clean_cmd)

    temp_out_dir = tempfile.mkdtemp(suffix='_out', prefix='infer_')
    infer_cmd = ['infer', '-a', analyzer, '-o', temp_out_dir, '--'] + build_cmd

    with tempfile.TemporaryFile(
            mode='w',
            suffix='.out',
            prefix='analysis_') as analysis_output:
        subprocess.check_call(infer_cmd, stdout=analysis_output)

    json_path = os.path.join(temp_out_dir, REPORT_JSON)
    found_errors = utils.load_json_from_path(json_path)
    shutil.rmtree(temp_out_dir)
    os.chdir(CURRENT_DIR)

    return found_errors


def match_pattern(f, p):
    for key in p.keys():
        if f[key] != p[key]:
            return False
    return True


def is_expected(e, patterns):
    for p in patterns:
        if match_pattern(e, p):
            return True
    return False


def is_missing(p, errors):
    for e in errors:
        if match_pattern(e, p):
            return False
    return True


def unexpected_errors(errors, patterns):
    return [e for e in errors if not is_expected(e, patterns)]


def missing_errors(errors, patterns):
    return [p for p in patterns if is_missing(p, errors)]


def check_results(errors, patterns):
    unexpected = unexpected_errors(errors, patterns)
    if unexpected != []:
        print('\nInfer found the following unexpected errors:')
        for e in unexpected:
            print('\t{}\n'.format(string_of_error(e)))
    missing = missing_errors(errors, patterns)
    if missing != []:
        print('\nInfer did not find the following errors:')
        for p in missing:
            print('\t{}\n'.format(string_of_error(p)))
    assert unexpected == []
    assert missing == []


def is_tool_available(cmd):
    try:
        subprocess.call(cmd)
    except OSError as e:
        if e.errno == os.errno.ENOENT:
            return False
        else:
            raise
    return True


def do_test(errors, expected_errors_filename):
    if should_record_tests():
        save_report(errors, expected_errors_filename)
        return
    else:
        patterns = utils.load_json_from_path(expected_errors_filename)
        check_results(errors, patterns)


class BuildIntegrationTest(unittest.TestCase):

    def test_ant_integration(self):
        if is_tool_available(['ant', '-version']):
            print('\nRunning Gradle integration test')
            root = os.path.join(CURRENT_DIR, 'infer', 'tests')
            errors = run_analysis(
                root,
                ['ant', 'clean'],
                ['ant', 'compile'],
                INFER_EXECUTABLE)
            do_test(errors, os.path.join(root, 'ant_report.json'))
        else:
            print('\nSkipping Ant integration test')
            assert True

    def test_gradle_integration(self):
        if is_tool_available(['gradle', '--version']):
            print('\nRunning Gradle integration test')
            root = os.path.join(CURRENT_DIR, 'examples', 'android_hello')
            errors = run_analysis(
                root,
                ['gradle', 'clean'],
                ['gradle', 'build'],
                INFER_EXECUTABLE)
            do_test(errors, os.path.join(root, 'gradle_report.json'))
        else:
            print('\nSkipping Gradle integration test')
            assert True

    def test_buck_integration(self):
        if is_tool_available(['buck', '--version']):
            print('\nRunning Buck integration test')
            root = CURRENT_DIR
            errors = run_analysis(
                root,
                ['buck', 'clean'],
                ['buck', 'build', 'infer'],
                INFER_EXECUTABLE)
            report_path = os.path.join(
                CURRENT_DIR, 'infer', 'tests', 'buck_report.json')
            do_test(errors, report_path)
        else:
            print('\nSkipping Buck integration test')
            assert True


if __name__ == "__main__":
    unittest.main()  # run all the tests
