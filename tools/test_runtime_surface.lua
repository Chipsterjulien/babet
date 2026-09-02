-- Exact top-level Babet runtime surface regression.
-- Candidate 10 adds this independently useful guard so a future section-GC
-- change cannot silently discard a registration path.

local expected = {
    VERSION=true, VERSION_MAJOR=true, VERSION_MINOR=true, VERSION_PATCH=true,
    archive=true, base64=true, compression=true, curses=true, gui=true,
    http=true, inotify=true, json=true, plugin=true, signal=true,
    socket=true, sqlite=true, time=true, toml=true, user=true,
    websocket=true, workers=true,

    setAttributes=true, getAttributes=true, chdir=true, copy=true,
    copyTree=true, crc32=true, crc32sum=true, currentDir=true,
    deepCopyTable=true, exec=true, spawn=true, pipeline=true,
    spawnPipeline=true, fileExists=true, fileSize=true, find=true,
    getBasename=true, getExtension=true, getFilename=true,
    getMemoryUsage=true, getDetailedMemoryUsage=true, getPath=true,
    helloThere=true, isDir=true, isdir=true, isFile=true, isfile=true,
    link=true, listFiles=true, md5sum=true, mergeTables=true, mkdir=true,
    moveTree=true, joinPath=true, remove=true, rename=true, rmdir=true,
    rmdirAll=true, setMode=true, getMode=true, sha1sum=true,
    sha3_256sum=true, sha3_512sum=true, sha256sum=true, sha512sum=true,
    blake2b512sum=true, blake2s256sum=true, sha384sum=true,
    sha3_384sum=true, sleep=true, monotonic=true, now=true, split=true,
    symlinkAttr=true, symlinkattr=true, touch=true, writeFileAtomic=true,
    createFileIterator=true, which=true, env=true, setenv=true,
    hostname=true, uname=true, pid=true,
}

local actual_count = 0
for key in pairs(babet) do
    actual_count = actual_count + 1
    assert(expected[key], "unexpected babet top-level entry: " .. tostring(key))
end

local expected_count = 0
for key in pairs(expected) do
    expected_count = expected_count + 1
    assert(babet[key] ~= nil, "missing babet top-level entry: " .. tostring(key))
end

assert(actual_count == expected_count,
       string.format("babet surface count mismatch: actual=%d expected=%d",
                     actual_count, expected_count))

local table_entries = {
    archive=true, base64=true, compression=true, curses=true, gui=true,
    http=true, inotify=true, json=true, plugin=true, signal=true,
    socket=true, sqlite=true, time=true, toml=true, user=true,
    websocket=true, workers=true,
}
for name in pairs(table_entries) do
    assert(type(babet[name]) == "table", "babet." .. name .. " is not a table")
end

print("BABET_RUNTIME_SURFACE_OK:" .. tostring(actual_count))
