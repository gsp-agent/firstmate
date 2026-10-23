import subprocess,concurrent.futures
modes=['race-branch','race-dirty','race-commits','race-owner']
def run(mode):
 p=subprocess.run(['python3','.test-runtime/live-scenarios.py',mode],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 print(mode,p.returncode,p.stdout,flush=True)
 return p.returncode
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 codes=list(pool.map(run,modes))
raise SystemExit(any(codes))
