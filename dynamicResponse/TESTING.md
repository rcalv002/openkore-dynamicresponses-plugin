# Testing Guide for dynamicResponse Plugin

Follow these steps to test and verify that the plugin is working correctly:

## Step 1: Configure API Access

1. Edit the `plugins/dynamicResponse/dynamicResponse.txt` file
2. Set your API key in the `apiKey` field
3. Verify the `apiEndpoint` is correct for your AI service

## Step 2: Test the Plugin

### Testing with Simple Messages

Send a message to your character containing common phrases like:
- "Hello there"
- "What's your name?"
- "How are you doing?"

### Testing with the Word "test"

The simple plugin version responds to the word "test". The full plugin responds to any message, but you can still try sending:
- "This is a test message"
- "Testing 123"
- "Can you pass this test?"

### Testing Rate Limits

1. Send multiple messages in quick succession
2. After the first response, the plugin will enter a cooldown (default 10 seconds)
3. During cooldown, it should either:
   - Fall back to static responses if `fallbackToStatic` is 1
   - Not respond at all if `fallbackToStatic` is 0

## Step 3: Check the Logs

Watch your OpenKore console for these messages:
- `[dynamicResponse] Message event received.`
- `[dynamicResponse] Received message: '...' from user '...', type: '...'`
- `[dynamicResponse] Generating AI response...`
- `[dynamicResponse] Got AI response: '...'`

If you see these messages but no response in-game, check:
1. The `args->{reply}` and `args->{return}` debug lines
2. That `autoResponse` is set to 1 in your `config.txt`

## Optimizing Response Time

The plugin now features a direct messaging system that bypasses OpenKore's built-in typing delay:

1. **Direct Messaging (Instant Responses)**:
   - Set `useDirectMessaging 1` in the configuration (enabled by default)
   - Responses should appear immediately after the AI generates them
   - You'll see the console message: `[dynamicResponse] Sending response directly (no delay)`

2. **Traditional System (With Typing Delay)**:
   - Set `useDirectMessaging 0` to use the original system
   - Responses will be delayed to simulate typing speed (10+ seconds for long messages)
   - You'll see the console message: `[dynamicResponse] Using built-in response system (with typing delay)`

If you're experiencing delays even with direct messaging enabled, check:
   - That the API endpoint is responding quickly (local endpoints are faster than remote)
   - That the `cooldown` value isn't too high (default is 10 seconds)

## Common Issues

1. **No messages in console**: Check if plugin is listed in `sys.txt` and enabled in configuration
2. **Messages seen but no responses**: Check your API key and endpoint
3. **Error messages**: Look for specific error messages about API connectivity
4. **Plugin crashes**: Try the simple plugin version to isolate the issue
5. **Responses with delay**: Verify that `useDirectMessaging 1` is set in your configuration

## Switching between Plugin Versions

To switch between the full and simple versions:
1. Edit `sys.txt`
2. Change `dynamicResponse` to `dynamicResponse_simple` (or vice versa)
3. Restart OpenKore

## Troubleshooting

If all else fails:
1. Enable more debug logging with `debug 1` in `config.txt`
2. Compare your responses with static responses in `chat_resp.txt`
3. Try using the OpenAI API manually (with curl or another tool) to verify it works
