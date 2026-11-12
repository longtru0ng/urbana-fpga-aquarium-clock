"""Simple display-area traffic and movement sanity model; not RTL simulation."""
WIDTH, HEIGHT = 320, 240
x = [55,135,235,75,200,110,260,155,192]
y = [32,57,83,106,132,155,180,202,216]
facing = [True,False,True,False,True,False,True,False,False]
base_y = y[:]
pauses = [0]*9
previous = list(zip(x,y,facing))
dirty_area = 0
full_baseline = 0
for tick in range(4800):
    for i in range(8):
        if pauses[i]:
            pauses[i] -= 1
            continue
        stride = 4 if i in (0,1,2,7) else 8
        if tick % stride != i % stride:
            continue
        halfw = 28 if i < 3 else 16
        left, right = halfw, WIDTH-halfw
        if facing[i] and x[i] >= right-1:
            facing[i] = False
            pauses[i] = 12+i
        elif not facing[i] and x[i] <= left:
            facing[i] = True
            pauses[i] = 12+i
        else:
            x[i] += 1 if facing[i] else -1
        if tick % (30+i*5) == 0 and i not in (5,):
            dy = 1 if (tick // (30+i*5)) % 2 else -1
            newy = y[i] + dy
            hh = 16 if i == 6 else 12
            if hh <= newy <= HEIGHT-hh:
                y[i] = newy
    x[8], y[8], facing[8] = x[7]+37, y[7]+14, facing[7]
    for i in range(9):
        hw,hh = (28 if i < 3 else 16), (16 if i==6 else 12)
        assert hw <= x[i] <= WIDTH-hw, (tick,i,x[i])
        assert hh <= y[i] <= HEIGHT-hh, (tick,i,y[i])
        oldx,oldy,olddir = previous[i]
        if (x[i],y[i],facing[i]) != previous[i]:
            dirty_area += (max(oldx,x[i])-min(oldx,x[i])+2*hw) * (max(oldy,y[i])-min(oldy,y[i])+2*hh)
        full_baseline += 2*(2*hw)*(2*hh)
    previous = list(zip(x,y,facing))
print("PASS: 120-second movement model; all sprites within screen")
print("Modeled fish-region transfer reduction: %.1f%%" % (100*(1-dirty_area/full_baseline)))
print("These estimates do not measure hardware FPS.")
