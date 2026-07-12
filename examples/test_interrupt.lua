-- test_interrupt.lua
print("PID:", babet.pid())
print("Dans 5 secondes, tu auras 30 secondes pour faire kill -USR1 " .. babet.pid())

babet.signal.handle("USR1", function()
    print(">>> callback SIGUSR1 exécuté")
    -- pas de os.exit ici : on laisse le sleep retourner
end)

babet.sleep(5, 's')

print("c'est parti, kill -USR1 " .. babet.pid())
local t0 = babet.monotonic()
local ok_, err = babet.sleep(30, 's')
local elapsed = babet.monotonic() - t0

print(string.format("sleep retour : ok=%s, err=%s, elapsed=%.3fs",
    tostring(ok_), tostring(err), elapsed))
print("Script continue normalement après l'interruption")
