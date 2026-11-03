import yaml

p = r"D:\Downloads\instabox-keeper\.github\workflows\instabox-keeper.yml"
d = yaml.safe_load(open(p, encoding="utf-8"))

trig = d.get(True) or d.get("on")
cron = trig["schedule"][0]["cron"]
job = d["jobs"]["keepalive"]
steps = job["steps"]
env = steps[1]["env"]

print("cron         :", cron)
print("runs-on      :", job["runs-on"])
print("timeout      :", job["timeout-minutes"])
print("permissions  :", d["permissions"])
print("concurrency  :", d["concurrency"])
print("steps        :", [s.get("name") for s in steps])
print("RUN_MINUTES  :", env["RUN_MINUTES"])
print("REST_MINUTES :", env["REST_MINUTES"])
print("MACHINE_ID   :", env["MACHINE_ID"])
print("state step if:", steps[2].get("if"))
print("YAML OK")
