-- CBC-STORM v4.0 :: Master Installer
-- Fetches the project from GitHub and installs it based on the selected node type.
-- Version 2.0 (Reflects new repo structure)

local function download(url)
    print("Downloading: " .. url)
    local response = http.get(url)
    if response then
        local content = response.readAll()
        response.close()
        return content
    else
        printError("Error: Failed to download file from " .. url)
        return nil
    end
end

local function install_node(node_type, paths_data)
    local repo_url = paths_data.repo
    local files_to_install = paths_data.node_types[node_type].files

    if not files_to_install then
        printError("Error: Unknown node type '" .. node_type .. "'")
        return
    end

    print("Starting installation for node type: " .. node_type)

    for i, file_path in ipairs(files_to_install) do
        local url = repo_url .. file_path
        local content = download(url)

        if content then
            -- Create directories if they don't exist
            -- This handles paths like "storm/core/kernel.lua"
            local parent_dir = file_path:match("(.+[/])")
            if parent_dir and not fs.exists(parent_dir) then
                print("Creating directory: " .. parent_dir)
                fs.makeDir(parent_dir)
            end

            -- Write the file
            local file = fs.open(file_path, "w")
            file.write(content)
            file.close()
            print("Installed: " .. file_path)
        else
            printError("Installation failed for: " .. file_path)
            return -- Stop installation on failure
        end
        sleep(0.1) -- Be nice to GitHub's API
    end

    -- Download the version file to mark installation as complete
    local version_url = repo_url .. paths_data.version_file
    local version_content = download(version_url)
    if version_content then
        local file = fs.open(paths_data.version_file, "w")
        file.write(version_content)
        file.close()
    end

    print("-----------------------------------------")
    print("Installation for '" .. node_type .. "' complete!")
    if node_type == "controller" then
        print("Please configure your files in /storm/config/ and run 'storm/update.lua' to start the kernel.")
    elseif node_type == "worker" then
        print("Run 'register' to connect to the Controller.")
    elseif node_type == "seed" then
        print("Seed is ready. Power down until needed for recovery.")
    end
end

-- Main execution
local args = { ... } -- Capture command-line arguments for automated calls

term.clear()
term.setCursorPos(1, 1)
print("CBC-STORM v4.0 Installer")
print("------------------------")

-- The paths.json file is now at the root of the repo
local paths_url = "https://raw.githubusercontent.com/edujime23/CBC-STORM/main/paths.json"
local paths_content = download(paths_url)

if not paths_content then
    printError("Could not download the file manifest. Check URL and internet connection.")
    return
end

local paths_data, err = textutils.unserializeJSON(paths_content)
if not paths_data then
    printError("Could not parse the file manifest. Is the JSON valid?")
    printError(err)
    return
end

local choice = args[1] -- Use the first argument if it exists

if not choice then
    print("Choose node type to install:")
    print("1. Controller (Master Node)")
    print("2. Worker (Cannon/Detector)")
    print("3. Seed (Recovery Node)")
    term.write("> ")
    choice = read()
end

if choice == "1" then
    install_node("controller", paths_data)
elseif choice == "2" then
    install_node("worker", paths_data)
elseif choice == "3" then
    install_node("seed", paths_data)
else
    printError("Invalid choice.")
end
