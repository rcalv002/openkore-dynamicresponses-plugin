# Dynamic Response Plugin for OpenKore

This plugin lets your OpenKore bot answer chat messages using OpenAI-compatible chat models, providing more natural, context-aware replies than the static entries in `chat_resp.txt`. It comes in two flavors—a full-featured version and a lightweight “simple” build—to help you test and debug quickly, and supports Docker deployments out of the box.

---

## Features

- **AI-powered replies** via OpenAI-style Chat Completions (e.g. `gpt-3.5-turbo`, `phi4-mini:latest`)
- **Conversation history** (configurable window) for coherent back-and-forth
- **Rate limiting** (`dynamicResponse_cooldown`) and **response caching** to control API usage
- **Static fallback** when the AI API is unavailable or on cooldown
- **Personality tuning**: define your bot’s “voice” via a prompt prefix
- **Simple test version** (`dynamicResponse_simple.pl`) that responds only to “test”
- **Docker-friendly** error handling and initialization checks
- **Detailed logging** of warnings/errors/responses for easier debugging

---

## Installation & Testing

1. **Copy plugins**  
   - Full version: `plugins/dynamicResponse/dynamicResponse.pl`  
   - Simple version: `plugins/dynamicResponse/dynamicResponse_simple.pl`

2. **Test the simple build**  
   - In `bots/bot1/sys.txt`, set  
     ```  
     loadPlugins 2  
     loadPlugins_list dynamicResponse_simple  
     ```  
   - In `bots/bot1/config.txt`, set  
     ```  
     autoResponse 1  
     ```  
   - Restart your bot and send a chat containing “test” to verify it replies.

3. **Switch to full version**  
   - In `sys.txt`, swap `dynamicResponse_simple` → `dynamicResponse`  
   - Configure your API key and other settings (see next section)  
   - Restart your bot

---

## Configuration

Edit either `control/config.txt` or `plugins/dynamicResponse/dynamicResponse.txt`:

```ini
# Enable/disable
dynamicResponse_enabled       1       # 1 = on, 0 = off

# OpenAI API
dynamicResponse_apiKey        YOUR_API_KEY_HERE
dynamicResponse_apiEndpoint   http://10.0.0.20:11435/v1/chat/completions

# Model & output
dynamicResponse_model         gpt-3.5-turbo
dynamicResponse_maxTokens     50
dynamicResponse_temperature   0.7     # 0 = deterministic, 1 = highly random
dynamicResponse_personality   You are a friendly Ragnarok Online player. Keep responses brief.

# Usage control
dynamicResponse_cooldown      10      # Seconds between API calls
dynamicResponse_historySize   4       # Exchanges to remember
dynamicResponse_fallbackToStatic 1     # Use chat_resp.txt if API is down
dynamicResponse_logResponses  1       # 1 = enable console logging
```

## Example personalities

# Cheerful helper
dynamicResponse_personality You are a cheerful Ragnarok Online player who loves helping newbies. Keep responses under 20 words.

# In-character merchant
dynamicResponse_personality You are a merchant in Prontera Bazaar. You speak about prices, items, and deals. Keep responses brief.

# Mysterious wanderer
dynamicResponse_personality You are a mysterious traveler speaking in riddles. Never explain directly. Keep replies under 30 words.
