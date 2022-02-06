import re,json
from typing import List
from src.execution.execution_task import Execution_Task

RUBBISH = (
    'ANTLR runtime and generated code versions disagree: ',
    'DeprecationWarning: Python 2 support is ending!'
    )
VT100 = re.compile('\x1b\[[^m]*m')

def is_rubbish(line):
    for r in RUBBISH:
        if r in line:
            return True
    return False

def sanitized(lines):
    slines = []
    for line in lines:
        if not is_rubbish(line):
            slines.append(VT100.sub('',line))
    return slines

def str2label(s):
    # Convert string to label satisfying:
    # - letters and digits remain unaffected
    # - other leading or trailing characters are removed
    # - sequences of other characters occurring inbetween are replaced by a single underscore
    l = []
    sep = False
    ch = False
    for c in s: # or "in s.lower()" (convert to lowercase)?
        if c.isalnum(): # "or c in '-'", to allow for - and maybe other characters?
            if sep:
                l.append('_')
                sep = False
            l.append(c)
            ch = True
        else:
            sep = ch
    return ''.join(l)

DOCKER_TIMEOUT = 'Docker container timed out'

def main(Parser):
    # Runs parser standalone, to test it or to re-parse output later on
    # Only works if result.log is the only input to the parser; task is set to None
    # We take care to preserve DOCKER_TIMEOUT, set by src/execution/execution.py
    import sys
    if len(sys.argv) not in (2,3):
        print(f"Usage: python3 {sys.argv[0]} result.log [result.json] > result.json")
        return
    with open(sys.argv[1]) as f:
        result_log = f.read().rstrip()
    if len(sys.argv) == 3:
        with open(sys.argv[2]) as f:
            result_json = json.load(f)
    else:
        result_json = {}
    timeout = 'errors' in result_json and DOCKER_TIMEOUT in result_json['errors']
    parser = Parser(None, result_log)
    for k,v in parser.result().items():
        result_json[k] = v
    if timeout and DOCKER_TIMEOUT not in result_json['errors']:
        result_json['errors'].append(DOCKER_TIMEOUT)
    print(json.dumps(result_json,indent=2))


class Parser:

    def __init__(self, task: 'Execution_Task', output: str):
        self._task     = task
        self._lines    = [] if output is None else sanitized(output.splitlines())
        self._findings = set()
        self._errors   = set()
        self._analysis = None

    def findings(self) -> List[str]:
        return sorted([str2label(f) for f in self._findings])

    def errors(self) -> List[str]:
        # Run is considered successful if self.errors() == set(), and unsuccessful otherwise
        # Make sure to add an error if the output is missing or incomplete
        return sorted(self._errors)

    def analysis(self):
        return self._analysis

    def result(self):
        return {
            "findings": self.findings(),
            "errors": self.errors(),
            "analysis": self.analysis()
            }

    def parseSarif(self, str, file_path_in_repo):
        pass
