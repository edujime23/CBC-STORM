-- CBC-STORM v4.0 :: Worker Registration
-- Version 3.0 - Simplified. Assumes crypto.lua is pre-installed.

-- 1. Setup
term.clear()
term.setCursorPos(1, 1)
print("CBC-STORM Worker Registration")
print("-----------------------------")

-- Load the pre-installed crypto library using an absolute path
local crypto = require("/storm/lib/crypto")

-- 2. Get Onboarding Channel from user
local ONBOARDING_CHANNEL
while not ONBOARDING_CHANNEL do
    term.write("Enter Controller Onboarding Channel (e.g., 65500): ")
    local input = tonumber(read())
    if input and input > 0 and input < 65536 then
        ONBOARDING_CHANNEL = input
    else
        printError("Invalid channel. Must be a number between 1 and 65535.")
    end
end

-- 3. Generate key pair and broadcast public key
print("Generating temporary key pair...")
local my_private_key, my_public_key = crypto.generate_key_pair()
local my_computer_id = os.computerID()

local modem = peripheral.find("modem")
if not modem then
    printError("No modem attached!")
    return
end
modem.open(ONBOARDING_CHANNEL)

print("Broadcasting join request on channel " .. ONBOARDING_CHANNEL .. "...")
local request_payload = {
    type = "WORKER_JOIN_REQUEST",
    id = my_computer_id,
    public_key = tostring(my_public_key)
}
modem.transmit(ONBOARDING_CHANNEL, ONBOARDING_CHANNEL, textutils.serialize(request_payload))

-- 4. Listen for encrypted response
print("Waiting for encrypted configuration from Controller...")
print("(The Controller operator must now approve this node.)")

local event, _, sender_channel, reply_port, msg_str, _ = os.pullEvent("modem_message")
local encrypted_payload, err = textutils.unserialize(msg_str)

if not encrypted_payload or encrypted_payload.id ~= my_computer_id then
    printError("Received invalid or unexpected message. Aborting.")
    if err then printError(err) end
    return
end

print("Encrypted payload received. Deriving shared secret...")
local controller_public_key = encrypted_payload.public_key
local shared_secret = crypto.generate_shared_secret(my_private_key, controller_public_key)

print("Decrypting configuration...")
local config_json = crypto.xor_cipher(encrypted_payload.data, shared_secret)
local config_data, json_err = textutils.unserializeJSON(config_json)

if not config_data then
    printError("Decryption failed or config data is corrupt. Aborting.")
    if json_err then printError(json_err) end
    return
end

-- 5. Save config and code, then execute
print("Registration successful! Saving files...")

if not fs.exists("storm") then fs.makeDir("storm") end

-- Save encrypted config
local config_enc_file = fs.open("storm/config.enc", "w")
config_enc_file.write(encrypted_payload.data)
config_enc_file.close()

-- Save the worker code
for file_name, file_content in pairs(config_data.code) do
    local parent_dir = file_name:match("(.+[/])")
    if parent_dir and not fs.exists("storm/" .. parent_dir) then
        fs.makeDir("storm/" .. parent_dir)
    end
    local file_path = "storm/" .. file_name
    local file = fs.open(file_path, "w")
    file.write(file_content)
    file.close()
    print("Wrote: " .. file_path)
end

-- Save the shared secret
local key_file = fs.open("storm/session.key", "w")
key_file.write(shared_secret)
key_file.close()

print("---------------------------------")
print("Setup complete. Deleting temp files and starting worker...")
fs.delete("register.lua")
fs.delete("/storm/lib/crypto.lua") -- No longer needed on worker
sleep(2)

os.run({}, "/storm/" .. config_data.startup_script)