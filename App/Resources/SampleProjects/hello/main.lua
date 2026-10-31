-- Sample LÖVE project bundled with Mobile Studio.
local t = 0

function love.load()
    love.graphics.setBackgroundColor(0.08, 0.09, 0.12)
    print("Hello from LÖVE " .. table.concat({ love.getVersion() }, ".", 1, 3))
    print("LuaJIT: " .. (jit and jit.version or "n/a") .. "  JIT on: " .. tostring(jit and jit.status()))
end

function love.update(dt)
    t = t + dt
end

function love.draw()
    local w, h = love.graphics.getDimensions()
    love.graphics.setColor(0.91, 0.29, 0.6)
    love.graphics.circle("fill", w / 2 + math.cos(t) * w / 4, h / 2 + math.sin(t * 1.3) * h / 4, 32)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("Edit main.lua in Mobile Studio and press Run", 12, 12)
end

function love.keypressed(key)
    print("keypressed", key)
end
