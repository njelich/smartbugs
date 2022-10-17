import os, string, time
import sb.io, sb.logging, sb.config
from sb.exceptions import SmartBugsError, InternalError

OUTPUT_FORMATS = ("json", "sarif", "sarif-per-contract", "sarif-summary")
HOME = os.path.expanduser("~") # cross-plattform safe
NOW = time.gmtime() # only use in main process, value may be different in sub-processes
PID = os.getpid()   # only use in main process, value may be different in sub-processes

class Settings:

    def __init__(self):
        self.frozen = False
        self.files = []
        self.runtime = False
        self.tools = []
        self.runid = "${YEAR}${MONTH}${DAY}_${HOUR}${MIN}"
        self.overwrite = False
        self.processes = 1
        self.timeout = None
        self.cpu_quota = None
        self.mem_limit = None
        self.results = os.path.join("results","${TOOL}","${RUNID}","${FILEBASE}")
        self.logfile = os.path.join("results","logs","${RUNID}.log")
        self.format = []
        self.quiet = False

        
    def freeze(self):
        if self.frozen:
            return
        self.frozen = True
        env = {
            'SBVERSION': sb.config.VERSION,
            'SBHOME':    sb.config.HOME,
            'HOME':      HOME,
            'PID':       PID,
            'YEAR':      str(NOW.tm_year).zfill(4), # year with century, four digits
            'MONTH':     str(NOW.tm_mon).zfill(2),  # month 01..12
            'DAY':       str(NOW.tm_mday).zfill(2), # day of month 01..31
            'HOUR':      str(NOW.tm_hour).zfill(2), # hour 00..23
            'MIN':       str(NOW.tm_min).zfill(2),  # minutes 00..59
            'SEC':       str(NOW.tm_sec).zfill(2),  # seconds 00..61
            'ZONE':      NOW.tm_zone,               # abbreviation of timezone name
        }

        try:
            self.runid = string.Template(self.runid).substitute(env)
        except KeyError as e:
            raise SmartBugsError(f"Unknown variable '{e}' in run id")

        try:
            self.logfile = string.Template(self.logfile).substitute(env, RUNID=self.runid)
        except KeyError as e:
            raise SmartBugsError(f"Unknown variable '{e}' in name of log file")

        self.results = string.Template(self.results).safe_substitute(env, RUNID=self.runid)
        self.results = string.Template(self.results)


    def resultdir(self, toolid, toolmode, absfn, relfn):
        if not self.frozen:
            raise InternalError("Template of result directory is accessed before settings have been frozen")
        absdir,filename = os.path.split(absfn)
        reldir = os.path.dirname(relfn)
        filebase,fileext = os.path.splitext(filename)
        fileext = fileext.replace('.','')
        try:        
            return self.results.substitute(
                TOOL=toolid, MODE=toolmode,
                ABSDIR=absdir, RELDIR=reldir,
                FILENAME=filename, FILEBASE=filebase, FILEEXT=fileext)
        except KeyError as e:
            raise SmartBugsError(f"Unknown variable '{e}' in template of result dir")


    def update(self, settings):

        if self.frozen:
            raise InternalError("Frozen settings cannot be updated")
        if isinstance(settings, str):
            s = sb.io.read_yaml(settings)
        elif isinstance(settings, dict):
            s = settings
        else:
            raise SmartBugsError(f"Settings cannot be updated by objects of type '{type(settings).__name__}'")

        for k,v in s.items():
            k = k.replace("-", "_")

            # attributes accepting None as a value
            if k in ("timeout", "cpu_quota", "mem_limit") and v in (None, 0, "0"):
               setattr(self, k, None)

            elif k in ("timeout", "cpu_quota", "processes"):
                try:
                    v = int(v)
                    assert v > 0
                    setattr(self, k, v)
                except:
                    raise SmartBugsError(f"'{k}' needs to be a positive integer (in {settings}).")

            elif k in ("tools"):
                if not isinstance(v,list):
                    v = [v]
                try:
                    setattr(self, k, [str(vi) for vi in v])
                except:
                    raise SmartBugsError(f"'{k}' needs to be a string or a list of strings (in {settings}).")

            elif k in ("files"):
                if not isinstance(v,list):
                    v = [v]
                try:
                    patterns = [str(vi) for vi in v]
                except:
                    raise SmartBugsError(f"'{k}' needs to be a string or a list of strings (in {settings}).")
                root_specs = []
                for pattern in patterns:
                    root_spec = pattern.split(":")
                    if len(root_spec) == 1:
                        root,spec = None,root_spec[0]
                    elif len(root_spec) == 2:
                        root,spec = root_spec[0],root_spec[1]
                    else:
                        raise SmartBugsError(f"File pattern {pattern} contains more than one colon (in {settings}).")
                    root_specs.append((root,spec))
                setattr(self, k, root_specs)

            elif k in ("runtime", "overwrite", "quiet"):
                try:
                    assert isinstance(v, bool)
                    setattr(self, k, v)
                except:
                    raise SmartBugsError(f"'{k}' needs to be a Boolean (in {settings}).")

            elif k in ("results", "logfile"):
                try:
                    setattr(self, k, str(v).replace("/",os.path.sep))
                except:
                    raise SmartBugsError(f"'{k}' needs to be a path (in {settings}).")

            elif k in ("runid"):
                try:
                    setattr(self, k, str(v))
                except:
                    raise SmartBugsError(f"'{k}' needs to be a string (in {settings}).")

            elif k == "format":
                if not isinstance(v,list):
                    v = [v]
                try:
                    assert all(vi in OUTPUT_FORMATS for vi in v)
                    setattr(self, k, list(set(v)))
                except:
                    raise SmartBugsError(f"'{k}' needs to be one or more of {'/'.join(OUTPUT_FORMATS)} (in {settings}).")

            elif k == "mem_limit":
                try:
                    v = str(v).replace(" ","")
                    if v[-1] in "kKmMgG":
                        assert int(v[:-1]) > 0
                    else:
                        assert int(v) > 0
                    setattr(self, k, v)
                except:
                    raise SmartBugsError(f"'{k}' needs to be a memory specifcation (in {settings}).")

            else:
                raise SmartBugsError(f"Invalid key '{k}' (in {settings}).")

    
    def dict(self):
        d = {}
        for k,v in self.__dict__.items():
            if k == "frozen":
                continue
            elif k == "results" and v and not isinstance(v,str):
                d[k] = self.results.template
            else:
                d[k] = v
        return d

    def __str__(self):
        l = [ f"{k}: {str(v)}" for k,v in self.dict().items() ]
        return f"{{{', '.join(l)}}}"
