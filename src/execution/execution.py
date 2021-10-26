from time import time
import sys
import json
import os
import traceback
from typing import List, Tuple, Dict


from datetime import timedelta
from multiprocessing import Pool, Manager

from src.output_parser.Parser import Parser
from src.execution.execution_task import Execution_Task
from src.output_parser.Vandal import Vandal
from src.output_parser.Pakala import Pakala
from src.output_parser.Conkas import Conkas
from src.output_parser.HoneyBadger import HoneyBadger
from src.output_parser.Maian import Maian
from src.output_parser.Manticore import Manticore
from src.output_parser.Mythril import Mythril
from src.output_parser.Osiris import Osiris
from src.output_parser.Oyente import Oyente
from src.output_parser.Securify import Securify
from src.output_parser.Slither import Slither
from src.output_parser.Smartcheck import Smartcheck
from src.output_parser.Solhint import Solhint
from src.execution.execution_task import Execution_Task
from src.logger import logs
from src.execution.docker_api import analyse_files
from src.output_parser.SarifHolder import SarifHolder


class Execution:

    def __init__(self, tasks: List['Execution_Task']):
        manager = Manager()
        self.tasks = tasks
        self.conf = tasks[0].execution_configuration
        self.tasks_done = manager.list()
        self.total_execution = manager.Value("i", 0)
        self.sarif_cache: Dict[str, SarifHolder] = manager.dict()

    @staticmethod
    def analyze(args: Tuple['Execution', 'Execution_Task']):
        (self, task) = args
        try:
            self.analyze_start(task)
            task.start_time = time()
            output = analyse_files(task)
            task.end_time = time()
            self.parse_results(task, output)
            self.analyze_end(task)
        except Exception as e:
            logs.print(e)

    def analyze_start(self, task: 'Execution_Task'):
        sys.stdout.write('\x1b[1;37m' + 'Analysing file [%d/%d]: ' %
                         (len(self.tasks_done) + 1, len(self.tasks)) + '\x1b[0m')
        sys.stdout.write('\x1b[1;34m' + task.file + '\x1b[0m')
        sys.stdout.write('\x1b[1;37m' + ' [' +
                         task.tool + ']' + '\x1b[0m' + '\n')

    def analyze_end(self, task: 'Execution_Task'):
        self.tasks_done.append(task)

        duration = task.end_time - task.start_time
        self.total_execution.value += task.end_time - task.start_time

        task_sec = len(self.tasks_done) / duration
        remaining_time = str(timedelta(seconds=round(
            (len(self.tasks) - len(self.tasks_done)) / task_sec)))

        duration_str = str(timedelta(seconds=round(duration)))
        line = "\x1b[1;37mDone [%d/%d, %s]: \x1b[0m\x1b[1;34m%s\x1b[0m\x1b[1;37m [%s] in %s \x1b[0mwith exit code: %d" % (
            len(self.tasks_done), len(self.tasks), remaining_time, task.file, task.tool, duration_str, task.exit_code)
        logs.print(line, '[%d/%d] ' % (len(self.tasks_done), len(self.tasks)) +
                   task.file + ' [' + task.tool + '] in ' + duration_str)

    def exec(self):
        self.start_time = time()

        with Pool(processes=self.conf.processes) as pool:
            pool.map(Execution.analyze, [(self, task, )
                     for task in self.tasks])

        if self.conf.aggregate_sarif:
            for task in self.tasks:
                sarif_file_path = os.path.join(
                    self.conf.output_folder, self.conf.execution_name, task.file_name + '.sarif')
                if not os.path.exists(os.path.dirname(sarif_file_path)):
                    os.makedirs(os.path.dirname(sarif_file_path))
                with open(sarif_file_path, 'w') as sarif_file:
                    json.dump(
                        self.sarif_cache[task.file_name].print(), sarif_file, indent=2)

        if self.conf.unique_sarif_output:
            sarif_holder = SarifHolder()
            for sarif_output in self.sarif_cache.values():
                for run in sarif_output.sarif.runs:
                    sarif_holder.addRun(run)

            sarif_file_path = os.path.join(
                self.conf.output_folder, self.conf.execution_name + '.sarif')

            if not os.path.exists(os.path.dirname(sarif_file_path)):
                os.makedirs(os.path.dirname(sarif_file_path))

            with open(sarif_file_path, 'w') as sarif_file:
                json.dump(sarif_holder.print(), sarif_file, indent=2)

        elapsed_time = round(time() - self.start_time)
        if elapsed_time > 60:
            elapsed_time_sec = round(elapsed_time % 60)
            elapsed_time = round(elapsed_time // 60)
            logs.print('Analysis completed. \nIt took %sm %ss to analyse all files.' % (
                elapsed_time, elapsed_time_sec))
        else:
            logs.print(
                'Analysis completed. \nIt took %ss to analyse all files.' % elapsed_time)

    def parse_results(self, task: 'Execution_Task', log_content: str):
        results = {
            'contract': task.file,
            'tool': task.tool,
            'start': task.start_time,
            'end': task.end_time,
            'exit_code': task.exit_code,
            'duration': task.end_time - task.start_time,
            'analysis': None,
            'success': False
        }
        output_folder = task.result_output_path()
        if not os.path.exists(output_folder):
            os.makedirs(output_folder)

        with open(os.path.join(output_folder, 'result.log'), 'w', encoding='utf-8') as f:
            f.write(log_content)

        try:
            parser = Execution.log_parser(task, log_content)
            results['analysis'] = parser.parse()
            results['success'] = parser.is_success()

            if self.conf.output_version == 'v2' or self.conf.output_version == 'all':
                if task.file_name not in self.sarif_cache:
                    sarif = SarifHolder()
                else:
                    sarif = self.sarif_cache[task.file_name]
                sarif.addRun(parser.parseSarif(results, task.file))
                self.sarif_cache[task.file_name] = sarif
        except Exception as e:
            traceback.print_exc()
            logs.print("Log parser error: %s" % e)
            # ignore
            pass

        if self.conf.output_version == 'v1' or self.conf.output_version == 'all':
            with open(os.path.join(output_folder, 'result.json'), 'w') as f:
                json.dump(results, f, indent=2)

        if self.conf.output_version == 'v2' or self.conf.output_version == 'all':
            with open(os.path.join(output_folder, 'result.sarif'), 'w') as sarif_file:
                json.dump(self.sarif_cache[task.file_name].printToolRun(
                    tool=task.tool), sarif_file, indent=2)

    @staticmethod
    def log_parser(task: 'Execution_Task', log: str) -> Parser:
        if task.tool == 'oyente':
            return Oyente(task, log)
        if task.tool == 'osiris':
            return Osiris(task, log)
        if task.tool == 'honeybadger':
            return HoneyBadger(task, log)
        if task.tool == 'smartcheck':
            return Smartcheck(task, log)
        if task.tool == 'solhint':
            return Solhint(task, log)
        if task.tool == 'maian':
            return Maian(task, log)
        if task.tool == 'mythril':
            return Mythril(task, log)
        if task.tool == 'securify':
            return Securify(task, log)
        if task.tool == 'slither':
            return Slither(task, log)
        if task.tool == 'manticore':
            return Manticore(task, log)
        if task.tool == 'conkas':
            return Conkas(task, log)
        if task.tool == 'pakala':
            return Pakala(task, log)
        if task.tool == 'vandal':
            return Vandal(task, log)
