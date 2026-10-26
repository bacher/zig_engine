"""Render same-geography coast samples using ReportLab's standard line chart."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import math

import reportlab
from reportlab.graphics import renderSVG
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics.shapes import Drawing, Line, Rect, String
from reportlab.lib.colors import HexColor, white


def field(row, *names):
    for name in names:
        if name in row:
            if row[name] in ('true', 'false'):
                return row[name] == 'true'
            return float(row[name])
    raise KeyError(names)


def spans(xs, flags):
    result = []
    begin = None
    for x, flag in zip(xs, flags):
        if flag and begin is None:
            begin = x
        elif not flag and begin is not None:
            result.append((begin - .5, x - .5))
            begin = None
    if begin is not None:
        result.append((begin - .5, xs[-1] + .5))
    return result


def y_bounds(values):
    low, high = min(values), max(values)
    extent = max(1, high-low)
    magnitude = 10 ** math.floor(math.log10(extent / 5))
    step = next(n*magnitude for n in (1,2,5,10) if n*magnitude >= extent / 5)
    return math.floor((low-step*.15)/step)*step, math.ceil((high+step*.15)/step)*step, step


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('csv', type=Path)
    parser.add_argument('--output', type=Path, required=True, help='Filename stem')
    parser.add_argument('--seed', type=int, default=12345)
    parser.add_argument('--attempt', type=int, default=0)
    args = parser.parse_args()
    rows = list(csv.DictReader(args.csv.open()))
    xs = [field(r, 'x') for r in rows]
    ys = {field(r, 'y') for r in rows}
    assert len(ys) == 1 and all(b-a == 1 for a,b in zip(xs,xs[1:]))
    height = {v:[field(r,v+'_height',v+'_terrain_height') for r in rows] for v in ('old','exact','approx')}
    coast = {v:[field(r,v+'_coast',v+'_coast_distance') for r in rows] for v in ('old','exact','approx')}
    water = [bool(field(r,'water','water_present')) for r in rows]
    sea = [field(r,'sea_level') for r in rows]
    collar = [not water[i] and coast['approx'][i] == 0 and coast['exact'][i] > 0 for i in range(len(rows))]
    colors = {v:HexColor(c) for v,c in {'old':'#80549e','exact':'#087e8b','approx':'#d26318'}.items()}
    labels = {'old':'Old macro field','exact':'Exact mainland index','approx':'Proposed approximation'}
    drawing = Drawing(900,610)
    drawing.add(Rect(0,0,900,610,fillColor=white,strokeColor=None))
    drawing.add(String(55,583,'Coast cross-section: the same seed, attempt and coordinates',fontName='Helvetica-Bold',fontSize=15,fillColor=HexColor('#172b3a')))
    drawing.add(String(55,563,f'Seed {args.seed}; attempt {args.attempt}; Y={int(next(iter(ys)))}; dotted line: macro join X=36736',fontName='Helvetica',fontSize=10.5,fillColor=HexColor('#4a5862')))
    legend_x = 55
    for v in ('old','exact','approx'):
        drawing.add(Line(legend_x,541,legend_x+23,541,strokeColor=colors[v],strokeWidth=2))
        drawing.add(String(legend_x+29,537,labels[v],fontName='Helvetica',fontSize=10))
        legend_x += {'old':175,'exact':200,'approx':210}[v]
    drawing.add(Line(legend_x,541,legend_x+23,541,strokeColor=HexColor('#347cb4'),strokeWidth=1,strokeDashArray=[4,3]))
    drawing.add(String(legend_x+29,537,'Sea level',fontName='Helvetica',fontSize=10))
    plot_x, plot_width = 85, 775
    def x_pixel(x):
        return plot_x+(x-xs[0])/(xs[-1]-xs[0])*plot_width
    panels = [(height,sea,309,193,'Terrain height (storage Z)'),(coast,None,82,182,'Coast scalar (blocks)')]
    for index,(values,extra,plot_y,plot_height,title) in enumerate(panels):
        drawing.add(String(plot_x,plot_y+plot_height+10,title,fontName='Helvetica-Bold',fontSize=10.5,fillColor=HexColor('#172b3a')))
        for flags,color in [(water,'#c4e6fa'),(collar,'#f7dea0')]:
            for left,right in spans(xs,flags):
                left,right = max(xs[0],left),min(xs[-1],right)
                drawing.add(Rect(x_pixel(left),plot_y,x_pixel(right)-x_pixel(left),plot_height,fillColor=HexColor(color),strokeColor=None))
        plot=LinePlot()
        plot.x,plot.y,plot.width,plot.height=plot_x,plot_y,plot_width,plot_height
        plot.data=[list(zip(xs,values[v])) for v in ('old','exact','approx')]
        for i,v in enumerate(('old','exact','approx')):
            plot.lines[i].strokeColor=colors[v]
            plot.lines[i].strokeWidth=1.8
        if extra:
            plot.data.append(list(zip(xs,extra)))
            plot.lines[3].strokeColor=HexColor('#347cb4')
            plot.lines[3].strokeWidth=1
            plot.lines[3].strokeDashArray=[4,3]
        plot.joinedLines=1
        plot.xValueAxis.valueMin,plot.xValueAxis.valueMax=xs[0],xs[-1]
        plot.xValueAxis.valueSteps=[x for x in range(int(xs[0]),int(xs[-1])+1,32)]
        plot.xValueAxis.visibleLabels=int(index==1)
        plot.xValueAxis.labelTextFormat='%d'
        plot.xValueAxis.labels.fontName='Helvetica'
        plot.xValueAxis.labels.fontSize=9
        plot.xValueAxis.strokeColor=HexColor('#a5b0b7')
        all_values=[v for series in values.values() for v in series]+(extra or [])
        low,high,step=y_bounds(all_values)
        if index==1:low=max(0,low)
        plot.yValueAxis.valueMin,plot.yValueAxis.valueMax,plot.yValueAxis.valueStep=low,high,step
        plot.yValueAxis.labelTextFormat='%d'
        plot.yValueAxis.labels.fontName='Helvetica'
        plot.yValueAxis.labels.fontSize=9
        plot.yValueAxis.visibleGrid=1
        plot.yValueAxis.gridStrokeColor=HexColor('#dce1e5')
        plot.yValueAxis.gridStrokeWidth=.5
        plot.yValueAxis.strokeColor=HexColor('#a5b0b7')
        drawing.add(plot)
        drawing.add(Line(x_pixel(36736),plot_y,x_pixel(36736),plot_y+plot_height,strokeColor=HexColor('#7b8187'),strokeWidth=.9,strokeDashArray=[2,3]))
    drawing.add(String(472,48,f'Storage X at Y={int(next(iter(ys)))}',textAnchor='middle',fontName='Helvetica',fontSize=10))
    water_text='Actual water' if any(water) else 'Actual land throughout (no water in slice)'
    collar_text='Extra zero collar: approximate=0, exact>0' if any(collar) else 'Extra zero collar: none in this slice'
    drawing.add(Rect(55,24,11,8,fillColor=HexColor('#c4e6fa'),strokeColor=None))
    drawing.add(String(72,24,water_text,fontName='Helvetica',fontSize=9))
    drawing.add(Rect(342,24,11,8,fillColor=HexColor('#f7dea0'),strokeColor=None))
    drawing.add(String(359,24,collar_text,fontName='Helvetica',fontSize=9))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    renderSVG.drawToFile(drawing,str(args.output.with_suffix('.svg')))
    summary={'csv':str(args.csv),'sha256':hashlib.sha256(args.csv.read_bytes()).hexdigest(),'renderer':'ReportLab LinePlot '+reportlab.Version,'seed':args.seed,'attempt':args.attempt,'y':int(next(iter(ys))),'x_range':[int(xs[0]),int(xs[-1])],'samples':len(rows),'actual_water_samples':sum(water),'extra_zero_collar_samples':sum(collar),'variants':{}}
    for v in height:
        summary['variants'][v]={'height_range':[min(height[v]),max(height[v])],'coast_range':[min(coast[v]),max(coast[v])],'maximum_adjacent_height_delta':max(abs(b-a) for a,b in zip(height[v],height[v][1:])),'maximum_adjacent_coast_delta':max(abs(b-a) for a,b in zip(coast[v],coast[v][1:]))}
        if 36735 in xs and 36736 in xs:
            indices=[xs.index(x) for x in (36735,36736)]
            summary['variants'][v]['reported_join']={'heights':[height[v][i] for i in indices],'coasts':[coast[v][i] for i in indices]}
    args.output.with_suffix('.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
