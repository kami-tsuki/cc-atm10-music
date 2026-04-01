---@diagnostic disable: undefined-global
local M = {}

function M.open(protocol)
    local session = {
        available = false,
        protocol = protocol or "cc-atm10-music",
        side = nil
    }

    if rednet then
        local modem = peripheral.find("ender_modem") or peripheral.find("modem")
        if modem then
            local side = peripheral.getName(modem)
            local ok = pcall(rednet.open, side)
            if ok then
                session.available = true
                session.side = side
            end
        end
    end

    function session:broadcast(message)
        if not self.available then
            return false
        end
        return pcall(rednet.broadcast, message, self.protocol)
    end

    function session:receive(timeout)
        if not self.available then
            if timeout and timeout > 0 then
                sleep(timeout)
            end
            return nil, nil
        end
        return rednet.receive(self.protocol, timeout)
    end

    return session
end

return M