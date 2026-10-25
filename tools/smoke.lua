local v = vector.create(1, 2, 3)
local w = v * 2 + vector.create(0, 1, 0)
print("vector", w.x, w.y, w.z, vector.magnitude(v), vector.dot(v, w))
print("math", math.clamp(5, 0, 3), math.atan2(1, 1))
local t0 = os.clock()
local s = vector.zero or vector.create(0,0,0)
for i = 1, 1000000 do s = s + vector.create(i, 0, 1) * 0.5 end
print(string.format("1e6 vector ops %.1f ms", (os.clock() - t0) * 1000))
