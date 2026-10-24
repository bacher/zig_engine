from pathlib import Path
import json,sys,numpy as np
from PIL import Image,ImageDraw,ImageFont
from reportlab.graphics import renderSVG
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics.shapes import Drawing,Line,Rect,String
from reportlab.lib.colors import HexColor,white
base=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/private/tmp/terrain-tuning-probe/results')
meta=json.loads((base/'metadata.json').read_text());stats=json.loads((base/'statistics.json').read_text())
dtype=np.dtype([('height','<u2',(5,)),('land','u1'),('climate','u1'),('relief','u1'),('owner','u1'),('coast','<u2'),('mountain','<u2')])
sites=meta['sites'][:4]
labels=['Legacy 192 / 4 octaves','Pre-tuning natural','A: hills32 + detail8','B: hills48 + detail12','C: hills40 + detail10']
colors=['#6e6e77','#cf5b35','#267bbd','#33894c','#8653aa']
arrays={s['label']:np.fromfile(base/(s['label']+'.bin'),dtype=dtype).reshape(512,512) for s in sites}
font_path='/System/Library/Fonts/Supplemental/Arial.ttf'
f=lambda n:ImageFont.truetype(font_path,n)
panel=256;gap=16;left=20;top=130;row=318;W=5*(panel+gap)+left;H=top+len(sites)*row+60
im=Image.new('RGB',(W,H),'#faf9f6');draw=ImageDraw.Draw(im)
draw.text((left,14),'Local inland relief at the same seed and coordinates',font=f(28),fill='#172b3a')
draw.text((left,52),'512 x 512 blocks per panel; shared color scale: -32 to +32 blocks from each patch inland median.',font=f(17),fill='#4a5862')
draw.text((left,79),'Shared natural mask: blue water, gold coast <96. + = center; pale grid cells = 64 x 64 blocks.',font=f(17),fill='#4a5862')
for c,label in enumerate(labels):draw.text((left+c*(panel+gap),top-26),label,font=f(17),fill=colors[c])
lo=np.array([54,103,148]);mid=np.array([245,242,229]);hi=np.array([166,95,47])
for row_i,site in enumerate(sites):
 d=arrays[site['label']];mask=(d['land']>0)&(d['coast']>=96)&(d['mountain']==0)
 y0=top+row_i*row
 for v,name in enumerate(meta['variants']):
  h=d['height'][...,v].astype(float);med=float(np.median(h[mask]));t=np.clip((h-med)/32,-1,1)
  rgb=np.where((t<0)[...,None],mid+(mid-lo)*t[...,None],mid+(hi-mid)*t[...,None]).astype('uint8')
  rgb[(d['land']>0)&~mask]=[237,220,165];rgb[d['land']==0]=[176,214,233]
  tile=Image.fromarray(rgb).transpose(Image.Transpose.FLIP_TOP_BOTTOM).resize((panel,panel),Image.Resampling.BOX)
  x0=left+v*(panel+gap);im.paste(tile,(x0,y0))
  for a in range(32,256,32):
   draw.line((x0+a,y0,x0+a,y0+255),fill=(218,218,211),width=1)
   draw.line((x0,y0+a,x0+255,y0+a),fill=(218,218,211),width=1)
  draw.line((x0+123,y0+127,x0+133,y0+127),fill='#1b2631',width=2);draw.line((x0+128,y0+122,x0+128,y0+132),fill='#1b2631',width=2)
  s=next(s for s in stats if s['site']==site['label'] and s['size']==512 and s['basis']=='inland_lowland' and s['variant']==name)
  draw.text((x0,y0+261),f"P95-P5 {s['p95_minus_p5']:g}; median64 {s['range64_median']:g}",font=f(15),fill='#263846')
  draw.text((x0,y0+281),f"{site['label']} ({site['x']},{site['y']})",font=f(13),fill='#52616a')
draw.text((left,H-40),'Relative colors compare local variation; base elevations differ. Statistics use every block; displayed images average 2 x 2 blocks.',font=f(15),fill='#52616a')
im.save(base/'height-comparison.png')

D=Drawing(1120,1120);D.add(Rect(0,0,1120,1120,fillColor=white,strokeColor=None))
D.add(String(52,1088,'Local inland cross-sections: legacy, current, and three hill candidates',fontName='Helvetica-Bold',fontSize=16,fillColor=HexColor('#172b3a')))
D.add(String(52,1066,'Same coordinates; heights relative to each 512-square inland median. Common vertical scale: -40 to +40 blocks.',fontName='Helvetica',fontSize=11))
D.add(String(52,1049,'Only land with coast >=96 and zero mountain uplift is plotted. Gaps exclude coastal ramps and water.',fontName='Helvetica',fontSize=10,fillColor=HexColor('#52616a')))
for v,label in enumerate(labels):
 x=52+v*210;D.add(Line(x,1027,x+20,1027,strokeColor=HexColor(colors[v]),strokeWidth=2));D.add(String(x+26,1023,label,fontName='Helvetica',fontSize=9))
for r,site in enumerate(sites):
 d=arrays[site['label']];mask=(d['land']>0)&(d['coast']>=96)&(d['mountain']==0)
 for col,axis in enumerate(['X','Y']):
  x0=60+col*550;y0=80+(3-r)*232;PW=480;PH=170
  D.add(String(x0,y0+PH+14,f"{site['label']} ({site['x']},{site['y']}) - {axis} section",fontName='Helvetica-Bold',fontSize=10))
  plot=LinePlot();plot.x=x0;plot.y=y0;plot.width=PW;plot.height=PH;plot.data=[];line_colors=[]
  axis_mask=mask[256,:] if axis=='X' else mask[:,256]
  for v in range(5):
   h=d['height'][...,v].astype(float);med=float(np.median(h[mask]));vals=(h[256,:] if axis=='X' else h[:,256])-med
   segment=[]
   for i in range(512):
    if axis_mask[i]:segment.append((i-256,float(vals[i])))
    elif segment:
     if len(segment)>1:plot.data.append(segment);line_colors.append(colors[v])
     segment=[]
   if len(segment)>1:plot.data.append(segment);line_colors.append(colors[v])
  plot.joinedLines=1
  for i,color in enumerate(line_colors):plot.lines[i].strokeColor=HexColor(color);plot.lines[i].strokeWidth=1.4
  plot.xValueAxis.valueMin=-256;plot.xValueAxis.valueMax=255;plot.xValueAxis.valueSteps=[-256,-128,0,128,255]
  plot.yValueAxis.valueMin=-40;plot.yValueAxis.valueMax=40;plot.yValueAxis.valueStep=20
  for a in [plot.xValueAxis,plot.yValueAxis]:a.labels.fontName='Helvetica';a.labels.fontSize=8;a.labelTextFormat='%d';a.strokeColor=HexColor('#a9b2b7')
  plot.yValueAxis.visibleGrid=1;plot.yValueAxis.gridStrokeColor=HexColor('#e1e5e8');plot.yValueAxis.gridStrokeWidth=.4
  D.add(plot);D.add(Line(x0+PW*256/511,y0,x0+PW*256/511,y0+PH,strokeColor=HexColor('#bcc3c8'),strokeWidth=.6,strokeDashArray=[2,3]))
  if r==3:D.add(String(x0+PW/2,y0-30,'Offset from patch center (blocks)',textAnchor='middle',fontName='Helvetica',fontSize=10))
D.add(String(52,25,'Seed12345; attempt0. Plotted inputs and complete local statistics are preserved beside this figure.',fontName='Helvetica',fontSize=9,fillColor=HexColor('#52616a')))
renderSVG.drawToFile(D,str(base/'cross-sections.svg'))
print(base/'height-comparison.png');print(base/'cross-sections.svg')
