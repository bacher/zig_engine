from pathlib import Path
import csv,json,sys,numpy as np
base=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/private/tmp/terrain-tuning-probe/results')
meta=json.loads((base/'metadata.json').read_text())
dtype=np.dtype([('height','<u2',(5,)),('land','u1'),('climate','u1'),('relief','u1'),('owner','u1'),('coast','<u2'),('mountain','<u2')]);assert dtype.itemsize==18
stats=[];arrays={}
for site in meta['sites']:
 data=np.fromfile(base/(site['label']+'.bin'),dtype=dtype).reshape(512,512);arrays[site['label']]=data
 for size in (256,512):
  o=(512-size)//2;patch=data[o:o+size,o:o+size]
  masks={'all_land':patch['land']>0,'inland_lowland':(patch['land']>0)&(patch['coast']>=96)&(patch['mountain']==0)}
  for basis,mask in masks.items():
   for v,name in enumerate(meta['variants']):
    h=patch['height'][...,v].astype(np.int32);values=h[mask]
    steps=np.concatenate((np.abs(np.diff(h,axis=1))[mask[:,1:]&mask[:,:-1]],np.abs(np.diff(h,axis=0))[mask[1:,:]&mask[:-1,:]]))
    ranges=[]
    for y in range(0,size,64):
     for x in range(0,size,64):
      if mask[y:y+64,x:x+64].all():ranges.append(int(np.ptp(h[y:y+64,x:x+64])))
    center=h[size//2-32:size//2+32,size//2-32:size//2+32];center_mask=mask[size//2-32:size//2+32,size//2-32:size//2+32];q=np.percentile(values,[5,50,95])
    s=dict(site=site['label'],x=site['x'],y=site['y'],size=size,basis=basis,variant=name,columns=int(mask.sum()),coverage_percent=float(mask.mean()*100),minimum=int(values.min()),maximum=int(values.max()),range=int(np.ptp(values)),p5=float(q[0]),median=float(q[1]),p95=float(q[2]),p95_minus_p5=float(q[2]-q[0]),stddev=float(values.std()),cardinal_step_mean=float(steps.mean()),cardinal_step_p95=float(np.percentile(steps,95)),cardinal_step_max=int(steps.max()),flat_steps_percent=float((steps==0).mean()*100),steps_le1_percent=float((steps<=1).mean()*100),center_range64=int(np.ptp(center[center_mask])),range64_tiles=len(ranges),range64_median=float(np.median(ranges)) if ranges else None,range64_p95=float(np.percentile(ranges,95)) if ranges else None,range64_max=max(ranges) if ranges else None)
    stats.append(s)
(base/'statistics.json').write_text(json.dumps(stats,indent=2)+'\n')
with (base/'statistics.csv').open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(stats[0]),lineterminator='\n');w.writeheader();w.writerows(stats)
with (base/'cross-sections.csv').open('w',newline='') as f:
 w=csv.writer(f,lineterminator='\n');w.writerow(['site','axis','offset','x','y','land','coast']+meta['variants'])
 for site in meta['sites']:
  d=arrays[site['label']]
  for axis in ('X','Y'):
   for i in range(512):
    px,py=(i,256) if axis=='X' else (256,i);r=d[py,px]
    w.writerow([site['label'],axis,i-256,(site['x']+px-256)%65536,site['y']+py-256,int(r['land']),int(r['coast'])]+[int(h) for h in r['height']])
print('512 inland-lowland patches: p95-p5 / median64 range / max cardinal step')
for s in stats:
 if s['size']==512 and s['basis']=='inland_lowland':print(f"{s['site']:23} {s['variant']:8} {s['p95_minus_p5']:5.1f} / {s['range64_median']:5.1f} / {s['cardinal_step_max']}")

# A compact spatial input for inspection; full-resolution512 grids need not be kept.
import gzip,io
with (base/'height-grids.csv.gz').open('wb') as raw:
 with gzip.GzipFile(filename='',fileobj=raw,mode='wb',mtime=0) as zipped:
  with io.TextIOWrapper(zipped,encoding='utf-8',newline='') as text:
   w=csv.writer(text,lineterminator='\n')
   w.writerow(['site','local_x0','local_y0','land_samples_of4','inland_samples_of4']+[v+'_mean_height_2x2' for v in meta['variants']])
   for site in meta['sites'][:4]:
    d=arrays[site['label']]
    for y in range(0,512,2):
     for x in range(0,512,2):
      block=d[y:y+2,x:x+2]
      inland=(block['land']>0)&(block['coast']>=96)&(block['mountain']==0)
      means=block['height'].astype(np.uint32).sum(axis=(0,1))/4
      w.writerow([site['label'],x-256,y-256,int((block['land']>0).sum()),int(inland.sum())]+[f'{n:g}' for n in means])
