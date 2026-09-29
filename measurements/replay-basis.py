#!/usr/bin/env python3
# Replays measurements/2026-08-21-rundown.csv.gz against the time-to-empty
# arithmetic (timeToEmpty + BatteryScale.constantPowerFactor, ported 1:1) on the
# two %/hr bases: NOMINAL voltage (what the power tiers used) and the pack's LIVE
# voltage (what they use now). The power fed in is the true mean power ahead,
# so the only thing under test is the basis.
#
#   python3 measurements/replay-basis.py      (run from the repo root)
#
# Reference = the discharge accumulator. InstantAmperage is NOT used as the
# reference: it integrates to 8.5% more charge than the gauge's own drop.
import gzip,csv,math
shape=[(12.5,0.95388),(15.0,0.95853),(17.5,0.96240),(20.0,0.96640),(22.5,0.96640),(25.0,0.97212),(27.5,0.97419),(30.0,0.97445),(32.5,0.97746),(35.0,0.98004),(37.5,0.98374),(40.0,0.98804),(42.5,0.98985),(45.0,0.99380),(47.5,0.99441),(50.0,1.0),(52.5,1.00551),(55.0,1.00654),(57.5,1.01523),(60.0,1.02031),(62.5,1.02986),(65.0,1.03648),(67.5,1.03665),(70.0,1.04500),(72.5,1.04982),(75.0,1.06178),(77.5,1.06565)]
up=[p for p in shape if p[0]>=45]; mx=sum(a for a,b in up)/len(up); my=sum(b for a,b in up)/len(up)
UPPER=sum((a-mx)*(b-my) for a,b in up)/sum((a-mx)**2 for a,b in up)
def relV(s,new=True):
    c=shape;s=min(100,max(0,s))
    if s<=c[0][0]:
        m=(c[1][1]-c[0][1])/(c[1][0]-c[0][0]);return max(0.774,c[0][1]+m*(s-c[0][0]))
    n=len(c)-1
    if s>=c[n][0]:
        m=UPPER if new else (c[n][1]-c[n-1][1])/(c[n][0]-c[n-1][0]);return c[n][1]+m*(s-c[n][0])
    i=0
    while i+1<len(c) and c[i+1][0]<s:i+=1
    f=(s-c[i][0])/(c[i+1][0]-c[i][0]);return c[i][1]+f*(c[i+1][1]-c[i][1])
def cpf(s,new=True):
    s=min(100,max(0,s))
    if s<=0:return 1
    v=relV(s,new);n=64;sm=0
    for j in range(n+1):
        w=0.5 if j in(0,n) else 1;sm+=w*relV(s*j/n,new)
    return min(1,max(0.5,sm/n/v))
rows=list(csv.DictReader(gzip.open('measurements/2026-08-21-rundown.csv.gz','rt')))
rows=[r for r in rows if r['ExternalConnected']=='0']
t=[float(r['awake']) for r in rows]
soc=[float(r['RemainingCapacity'])/float(r['FullChargeCapacity'])*100 for r in rows]
V=[float(r['Voltage']) for r in rows]; I=[-float(r['InstantAmperage']) for r in rows]
P=[v*i/1e6 for v,i in zip(V,I)]
FCC=float(rows[0]['FullChargeCapacity']); end=soc[-1]; tend=t[-1]
# energy delivered (J) cumulative via trapezoid, to get mean power over remainder
E=[0.0]
for k in range(1,len(t)):E.append(E[-1]+(P[k]+P[k-1])/2*(t[k]-t[k-1]))
print(f"samples {len(rows)}  soc {soc[0]:.1f}->{end:.1f}  hours {(tend-t[0])/3600:.2f}  FCC {FCC:.0f}")
res={'nominal':[], 'live':[]}
for k in range(0,len(rows)-200,50):
    s=soc[k]; rem=tend-t[k]
    Pm=(E[-1]-E[k])/rem  # the true mean power ahead: isolates the basis
    for name,Vx in (('nominal',11.58),('live',V[k]/1000)):
        rate=Pm*1e5/(FCC*Vx)
        # app formula generalised to stop at `end`: time = (s*cpf(s) - end*cpf(end)*relV(end)/relV(s)) / rate
        pred=(s*cpf(s) - end*cpf(end)*relV(end)/relV(s))/rate*3600
        res[name].append((pred-rem)/rem*100)
for n,e in res.items():
    import statistics as st
    print(f"{n:8s} mean err {st.mean(e):+.2f}%  mean |err| {st.mean(abs(x) for x in e):.2f}%  worst {max(e,key=abs):+.2f}%")
Q=0.0
for k in range(1,len(t)):Q+=(I[k]+I[k-1])/2*(t[k]-t[k-1])/3600
dR=float(rows[0]['RemainingCapacity'])-float(rows[-1]['RemainingCapacity'])
print(f"integrated current {Q:.0f} mAh vs gauge drop {dR:.0f} mAh  ratio {Q/dR:.3f}")
gaps=[t[k]-t[k-1] for k in range(1,len(t))]; print("max gap s",max(gaps), "median", sorted(gaps)[len(gaps)//2])
# accumulator power vs V*I
a0,a1=rows[0],rows[-1]
dacc=int(a1['AccumulatedBatteryDischarge'])-int(a0['AccumulatedBatteryDischarge']); dcnt=int(a1['BatteryDischargeAccumulatorCount'])-int(a0['BatteryDischargeAccumulatorCount'])
print("accumulator mean mW",dacc/dcnt if dcnt else None, " V*I mean W", E[-1]/(tend-t[0]))
print("--- reference = discharge accumulator (the gauge's own energy count)")
acc=[int(r['AccumulatedBatteryDischarge']) for r in rows]; cnt=[int(r['BatteryDischargeAccumulatorCount']) for r in rows]
import statistics as st
for label,lo,hi in (("all",0,101),(">=60%",60,101),("30-60%",30,60)):
  res={'nominal':[], 'live':[]}
  for k in range(0,len(rows)-400,25):
    if not(lo<=soc[k]<hi):continue
    if cnt[-1]==cnt[k]:continue
    Pm=-(acc[-1]-acc[k])/(cnt[-1]-cnt[k])/1000   # W, 1 Hz ticks
    rem=tend-t[k]; s=soc[k]
    for name,Vx in (('nominal',11.58),('live',V[k]/1000)):
        rate=Pm*1e5/(FCC*Vx)
        pred=(s*cpf(s)-end*cpf(end)*relV(end)/relV(s))/rate*3600
        res[name].append((pred-rem)/rem*100)
  for n,e in res.items():
    print(f"{label:7s} {n:8s} n={len(e):3d} mean err {st.mean(e):+.2f}%  mean |err| {st.mean(abs(x) for x in e):.2f}%")
