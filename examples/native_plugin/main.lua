local plugin, err = babet.plugin.load(assert(arg[1], "plugin path required"))
assert(plugin, err)
print(plugin.name, plugin.version)
for name, fn in pairs(plugin.functions) do
    print(name, type(fn))
end
