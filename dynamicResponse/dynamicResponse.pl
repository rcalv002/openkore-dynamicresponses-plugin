package dynamicResponse;

use strict;
use warnings;
use Plugins;
use Settings;
use Globals qw($messageSender $char %config);
use Log qw(message warning error debug);
use Time::HiRes qw(time);
use Encode;
use utf8;
use Storable qw(dclone); # Add Storable for deep copying

# Plugin hook registration
Plugins::register("dynamicResponse", "Respond to chat messages using OpenAI", \&onUnload);
my $hooks = Plugins::addHooks(
    ['ChatQueue::processChatResponse', \&onChatResponse, undef],
    ['AI_pre', \&onAI_pre, undef],
    ['start3', \&onStart, undef],
);

# Plugin settings
my $plugin_folder = $Plugins::current_plugin_folder || "plugins/dynamicResponse";
my $config_file = $plugin_folder . "/dynamicResponse.txt";

# Plugin state variables
my %cached_responses;
my $last_api_call_time = 0;
my %conversation_history;
my $initialized = 0;
my $has_required_modules = 0;
my $message_counter = 0;

# Default settings
my %defaults = (
    enabled => 1,
    apiKey => "",
    model => "phi4-mini:latest",
    maxTokens => 50,
    temperature => 0.7,
    personality => "You are a friendly Ragnarok Online player. Keep responses brief and stay in character.",
    cooldown => 10,  # Seconds between API calls
    fallbackToStatic => 1,
    historySize => 4,
    logResponses => 1,
    apiEndpoint => "http://10.0.0.20:11435/v1/chat/completions",
    useDirectMessaging => 1,  # Use direct messaging (faster) instead of built-in response system
    apiFormat => "auto",      # auto, openai, ollama, simple, etc.
);

# API Format flags
my $use_alternative_format = 0;  # Set by test function if needed

# Plugin settings
our %plugin_config;

# Unload function
sub onUnload {
    Plugins::delHooks($hooks);
    message "[dynamicResponse] Plugin unloaded\n", "success";
}

# Plugin initialization
sub onStart {
    message "[dynamicResponse] Plugin initialized - Version 3.1 (Debug)\n", "success";
    message "[dynamicResponse] Waiting for chat messages to respond via AI...\n", "success";

    # Check for required modules
    eval {
        require JSON::Tiny;
        JSON::Tiny->import(qw(encode_json decode_json));
        require LWP::UserAgent;
        require HTTP::Request;
        require HTTP::Headers;
        $has_required_modules = 1;
        message "[dynamicResponse] All required modules loaded successfully\n", "success";
    };
    if ($@) {
        error "[dynamicResponse] Missing required modules: $@\n";
        error "[dynamicResponse] Plugin disabled due to missing dependencies\n";
        $has_required_modules = 0;
        $initialized = 1; # Still mark as initialized to avoid repeated errors
        return;
    }

    # First, load settings
    eval {
        message "[dynamicResponse] Loading configuration...\n", "success";
        loadPluginConfig();
    };
    if ($@) {
        error "[dynamicResponse] Error loading configuration: $@\n";
        error "[dynamicResponse] Using default settings\n";
        %plugin_config = %defaults;
    }

    # Check for API key
    if ($plugin_config{enabled} && (!$plugin_config{apiKey} || $plugin_config{apiKey} eq "" || $plugin_config{apiKey} eq "YOUR_API_KEY_HERE")) {
        warning "[dynamicResponse] WARNING: No API key set. Plugin will be disabled until key is provided.\n";
        $plugin_config{enabled} = 0;
    } else {
        message "[dynamicResponse] Plugin is " . ($plugin_config{enabled} ? "enabled" : "disabled") . "\n", "success";

        # Only run the API test if we have a key and the plugin is enabled
        if ($plugin_config{enabled} && $has_required_modules) {
            eval {
                message "[dynamicResponse] Testing API connectivity...\n", "success";
                testApiConnection();
            };
            if ($@) {
                error "[dynamicResponse] API connection test failed: $@\n";
                warning "[dynamicResponse] Plugin will still run but API calls may fail\n";
            }
        }
    }

    # Try to create config directory if it doesn't exist
    unless (-d $plugin_folder) {
        eval {
            mkdir $plugin_folder;
            message "[dynamicResponse] Created plugin folder: $plugin_folder\n", "success";
        };
        if ($@) {
            warning "[dynamicResponse] WARNING: Could not create plugin folder. Settings will not be saved.\n";
        }
    }

    # Check if autoResponse is enabled in config
    if ($config{autoResponse}) {
        message "[dynamicResponse] AutoResponse is enabled in config.txt (autoResponse = $config{autoResponse})\n", "success";
    } else {
        warning "[dynamicResponse] WARNING: AutoResponse is disabled in config.txt! Our plugin may not work.\n";
    }

    $initialized = 1;
}

# AI_pre hook callback
sub onAI_pre {
    return unless $initialized;
    return if (!$plugin_config{enabled} || !$has_required_modules);

    # Every 100 AI cycles (approximately every few seconds)
    if ($message_counter % 100 == 0) {
        debug "[dynamicResponse] Plugin is active and waiting for messages. Counter: $message_counter\n", "plugin";
    }
    $message_counter++;
}

# Chat response hook callback
sub onChatResponse {
    return unless $initialized;
    return unless $has_required_modules;
    return if (!$plugin_config{enabled});

    my ($hook, $args) = @_;

    # Log that we received a chat message event
    message "[dynamicResponse] Message event received.\n", "success";

    # Check if args are defined
    if (!defined $args) {
        error "[dynamicResponse] ERROR: args not defined!\n";
        return;
    }

    # Check if msg is defined
    if (!defined $args->{msg}) {
        error "[dynamicResponse] ERROR: args->{msg} not defined!\n";
        return;
    }

    # Check if char is defined
    if (!defined $char) {
        error "[dynamicResponse] ERROR: char not defined!\n";
        return;
    }

    # Check if char name is defined
    if (!defined $char->{name}) {
        error "[dynamicResponse] ERROR: char->{name} not defined!\n";
        return;
    }

    my $msg = $args->{msg};
    my $user = $args->{user} || "Unknown";
    my $type = $args->{type} || "c";

    # Log every message that comes through
    message "[dynamicResponse] Received message: '$msg' from user '$user', type: '$type'\n", "success";

    # Don't process our own messages
    if ($user eq $char->{name}) {
        message "[dynamicResponse] Skipping our own message.\n", "success";
        return;
    }

    # Check cooldown
    my $now = time;
    if ($now - $last_api_call_time < $plugin_config{cooldown}) {
        if ($plugin_config{fallbackToStatic}) {
            message "[dynamicResponse] On cooldown, falling back to static responses\n", "success";
            return;
        } else {
            # Skip response entirely
            message "[dynamicResponse] On cooldown, skipping response entirely\n", "success";
            $args->{return} = 1;
            return;
        }
    }

    # Check cache
    if (exists $cached_responses{$msg}) {
        my $response = $cached_responses{$msg};
        message "[dynamicResponse] Using cached response for: $msg\n", "success";

        # Send the cached response
        if ($plugin_config{useDirectMessaging} && $messageSender && $type) {
            # Send message directly without delay
            message "[dynamicResponse] Sending cached response directly: '$response'\n", "success";
            sendMessage($messageSender, $type, $response, $user);
            $args->{return} = 1;  # Prevent further processing
        } else {
            # Use the traditional method with built-in delay
            message "[dynamicResponse] Using built-in response system for cached response\n", "success";
            $args->{reply} = $response;
            $args->{return} = 1;
        }

        return;
    }

    # Generate response via API
    my $response;
    eval {
        message "[dynamicResponse] Generating AI response...\n", "success";
        $response = generateResponse($user, $msg);
    };
    if ($@) {
        error "[dynamicResponse] Error generating response: $@\n";
        if ($plugin_config{fallbackToStatic}) {
            message "[dynamicResponse] Error in API call, falling back to static responses\n", "success";
            return;
        } else {
            message "[dynamicResponse] Error in API call, skipping response entirely\n", "success";
            $args->{return} = 1;
            return;
        }
    }

    # If we got a response, use it
    if (defined $response && $response ne '') { # Check if response is defined and not empty
        message "[dynamicResponse] Got AI response (raw): '$response'\n", "success";

        # Clean up potential leading/trailing whitespace before checking for IGNORE
        $response =~ s/^\s+|\s+$//g;

        # Check if the response is exactly "IGNORE"
        if (uc($response) eq 'IGNORE') {
            message "[dynamicResponse] AI determined message is not for this bot. Ignoring.\n", "success";
            $args->{return} = 1; # Prevent further processing / sending
            return;
        }

        # If not IGNORE, proceed with sending
        message "[dynamicResponse] AI response is not IGNORE. Proceeding to send.\n", "success";

        if ($plugin_config{useDirectMessaging} && $messageSender && $type) {
            # Send message directly without delay
            use utf8; # Ensure utf8 is enabled for length check
            my $max_len = 230;
            if (length($response) > $max_len) {
                message "[dynamicResponse] Response length (".length($response).") exceeds $max_len. Splitting message.\n", "success";
                my @chunks;
                my $current_chunk = "";
                my @words = split /(\s+)/, $response; # Split by whitespace, keeping delimiters

                for (my $i = 0; $i < @words; $i++) {
                    my $word = $words[$i];
                    # If adding the next word (and potential space) exceeds max length
                    if (length($current_chunk) + length($word) > $max_len) {
                        # If the current chunk is not empty, push it
                        if (length($current_chunk) > 0) {
                            push @chunks, $current_chunk;
                            $current_chunk = "";
                        }
                        # If the word itself is too long, split it hard
                        while (length($word) > $max_len) {
                             push @chunks, substr($word, 0, $max_len);
                             $word = substr($word, $max_len);
                        }
                    }
                    # Add the word to the current chunk
                    $current_chunk .= $word;
                }
                # Add the last chunk if it's not empty
                if (length($current_chunk) > 0) {
                    push @chunks, $current_chunk;
                }

                # Send each chunk
                for my $chunk (@chunks) {
                    # Trim whitespace from chunk before sending
                    $chunk =~ s/^\s+|\s+$//g;
                    if (length($chunk) > 0) {
                        sendMessage($messageSender, $type, $chunk, $user);
                        # Optional: Add a small delay between messages if needed
                        # Time::HiRes::sleep(0.5);
                    }
                }

            } else {
                # Send the single message
                sendMessage($messageSender, $type, $response, $user);
            }
            $args->{return} = 1;  # Prevent further processing by other handlers

        } else {
            # Use the traditional method with built-in delay
            message "[dynamicResponse] Using built-in response system (with typing delay)\n", "success";
            # Truncate if necessary for the built-in system
            if (length($response) > 230) {
                warning "[dynamicResponse] Response truncated to 230 characters for built-in system.\n";
                $response = substr($response, 0, 230);
            }
            $args->{reply} = $response;
            $args->{return} = 1;
        }

        $last_api_call_time = $now;

        # Cache the original, potentially long, response
        $cached_responses{$msg} = $response; # Note: Caching the potentially truncated response if not using direct messaging

        # Trim cache if it gets too large
        if (scalar(keys %cached_responses) > 100) {
            my @keys = keys %cached_responses;
            delete $cached_responses{$keys[0]};
        }
    } else {
        # If no response and fallback is enabled, let the default handler process it
        if ($plugin_config{fallbackToStatic}) {
            message "[dynamicResponse] No API response, falling back to static responses\n", "success";
            return;
        } else {
            # Otherwise, set return to 1 to skip response
            message "[dynamicResponse] No API response and fallback disabled, skipping response entirely\n", "success";
            $args->{return} = 1;
        }
    }
}

# Helper function to send a message directly
sub sendMessage {
    my ($messageSender, $type, $message, $user) = @_;

    if (!defined $messageSender) {
        error "[dynamicResponse] MessageSender not defined\n";
        return;
    }

	# 1) Remove leading “From: …;” (with optional surrounding whitespace/newline)
	$message =~ s/^\s*From:\s*[^;]+;\s*\n?//;

	# 2) Trim any leftover leading/trailing whitespace
	$message =~ s/^\s+|\s+$//g;

    # Convert type to the correct code and send message
    if ($type eq 'c') {
        # Public chat
        $messageSender->sendChat($message);
        message "[dynamicResponse] Sent public chat: $message\n", "success";
    } elsif ($type eq 'pm') {
        # Private message
        $messageSender->sendPrivateMsg($user, $message);
        message "[dynamicResponse] Sent PM to $user: $message\n", "success";
    } elsif ($type eq 'p') {
        # Party chat
        $messageSender->sendPartyChat($message);
        message "[dynamicResponse] Sent party chat: $message\n", "success";
    } elsif ($type eq 'g') {
        # Guild chat
        $messageSender->sendGuildChat($message);
        message "[dynamicResponse] Sent guild chat: $message\n", "success";
    } else {
        error "[dynamicResponse] Unknown chat type: $type\n";
    }
}

# Helper function to load plugin configuration
sub loadPluginConfig {
    # First load defaults
    %plugin_config = %defaults;

    # Then try to load from plugin config file FIRST
    if (-f $config_file) {
        eval {
            open my $fh, "<:utf8", $config_file;
            while (my $line = <$fh>) {
                next if ($line =~ /^#/);
                if ($line =~ /^\s*(\w+)\s+(.+?)\s*$/) {
                    my $key = $1;
                    my $value = $2;
                    # Trim any whitespace or control characters
                    $value =~ s/[\r\n\t\s]+$//g;
                    $value =~ s/^[\r\n\t\s]+//g;
                    $plugin_config{$key} = $value;

                    # Debug output for important values
                    if ($key eq "model" || $key eq "apiEndpoint") {
                        message "[dynamicResponse] Config loaded from $config_file: $key = '$value' (length: " . length($value) . ")\n", "success";
                    }
                }
            }
            close $fh;
        };
        if ($@) {
            warning "[dynamicResponse] WARNING: Failed to read config file $config_file: $@\n";
        }
    }

    # THEN try to load overrides from main config.txt
    # These will overwrite defaults AND plugin-specific file settings if they exist
    foreach my $key (keys %defaults) {
        if (exists $config{"dynamicResponse_$key"}) {
            $plugin_config{$key} = $config{"dynamicResponse_$key"};
             message "[dynamicResponse] Config override from config.txt: $key = '$plugin_config{$key}'\n", "success";
        }
    }

    # Try to save config back to file, but don't fail if we can't
    # This will now save the potentially overridden values
    eval {
        savePluginConfig();
    };
    if ($@) {
        warning "[dynamicResponse] WARNING: Failed to save config file: $@\n";
    }
}

# Helper function to save plugin configuration
sub savePluginConfig {
    eval {
        open my $fh, ">:utf8", $config_file;
        print $fh "# dynamicResponse plugin configuration\n";
        print $fh "# Created or modified at " . localtime() . "\n\n";

        foreach my $key (sort keys %plugin_config) {
            print $fh "$key $plugin_config{$key}\n";
        }
        close $fh;
    };
    if ($@) {
        warning "[dynamicResponse] WARNING: Failed to save config file: $@\n";
    }
}

# Function to update conversation history
sub updateHistory {
    my ($user, $message, $response) = @_;

    # Ensure $char and $char->{name} are defined
    my $bot_name = (defined $char && defined $char->{name}) ? $char->{name} : "Bot";

    if (!exists $conversation_history{$user}) {
        $conversation_history{$user} = [];
    }

    # Add message pair to history, including sender and responder names
    push @{$conversation_history{$user}}, {
        sender    => $user,
        message   => $message,
        responder => $bot_name,
        response  => $response,
        time      => time,
    };

    # Trim history if it gets too long
    if (scalar(@{$conversation_history{$user}}) > $plugin_config{historySize}) {
        shift @{$conversation_history{$user}};
    }
}

# Function to build conversation history for API request
sub buildConversationMessages {
    my ($user, $message) = @_;

    # Ensure $char and $char->{name} are defined
    my $bot_name = (defined $char && defined $char->{name}) ? $char->{name} : "Bot";

    # Include the bot's name in the personality/system prompt
    my $system_prompt = $plugin_config{personality};
    # Prepend the bot's name instruction and the IGNORE instruction to the system prompt
    $system_prompt = "Your name is $bot_name. " . $system_prompt . " Analyze the conversation history and the latest message ('From: UserName; message content'). Determine if the latest message is directed specifically at you, $bot_name, or is related to you (Maybe another bot referenced you). If it is, generate a helpful and in-character response. If the message is *not* directed at you (e.g., it's general chat, directed at someone else, or a message you shouldn't respond to), reply *only* with the single word 'IGNORE'.";

    my @messages = (
        {
            role => "system",
            content => $system_prompt
        }
    );

    # Add conversation history if it exists
    if (exists $conversation_history{$user}) {
        foreach my $entry (@{$conversation_history{$user}}) {
            # Add user message with sender's name prepended to content
            push @messages, {
                role => "user",
                content => "From: " . $entry->{sender} . '; ' . $entry->{message}
            };
            # Add assistant response with responder's name prepended to content
            push @messages, {
                role => "assistant",
                content => $entry->{response}
            };
        }
    }

    # Add current message with sender's name prepended to content
    push @messages, {
        role => "user",
        content => "From : " . $user . "; " . $message
    };

    return \@messages;
}

# Function to test API connectivity using a simple request
sub testApiConnection {
    # Skip if required modules aren't available
    return unless $has_required_modules;

    # Ensure model name is properly trimmed for test request
    my $model_name = $plugin_config{model};
    $model_name =~ s/[\r\n\t\s]+$//g;
    $model_name =~ s/^[\r\n\t\s]+//g;

    message "[dynamicResponse] Test using model: '$model_name' (length: " . length($model_name) . ")\n", "success";

    # Create a very simple test request
    my $test_data = {
        model => $model_name,
        messages => [
            {
                role => "system",
                content => "You are a helpful assistant."
            },
            {
                role => "user",
                content => "Hello, this is a test message. Please reply with 'Test successful'."
            }
        ],
        max_tokens => 20,
        temperature => 0.7,
    };

    message "[dynamicResponse] Test API Request Payload:\n", "success";
    eval {
        my $test_json = encode_json($test_data);
        message $test_json . "\n", "success";

        # Create request
        my $ua = LWP::UserAgent->new;
        $ua->timeout(10);

        my $headers = HTTP::Headers->new(
            'Content-Type' => 'application/json',
            'Authorization' => "Bearer $plugin_config{apiKey}"
        );

        my $request = HTTP::Request->new('POST', $plugin_config{apiEndpoint}, $headers, $test_json);

        # Send test request
        message "[dynamicResponse] Sending test request to: $plugin_config{apiEndpoint}\n", "success";
        my $response = $ua->request($request);

        # Log response
        message "[dynamicResponse] Test API response status: " . $response->status_line . "\n", "success";
        message "[dynamicResponse] Test API response content:\n" . $response->content . "\n", "success";

        if (!$response->is_success) {
            if ($response->code == 400) {
                error "[dynamicResponse] Test API call failed with Bad Request (400)\n";
                # Try with different format for OpenAI/Ollama compatibility
                message "[dynamicResponse] Attempting with alternative format for compatibility...\n", "success";

                # Some endpoints use slightly different format
                $test_data = {
                    model => $model_name,  # Use trimmed model name here too
                    prompt => "You are a helpful assistant.\n\nHello, this is a test message. Please reply with 'Test successful'.",
                    max_tokens => 20,
                    temperature => 0.7,
                };

                my $alt_json = encode_json($test_data);
                my $alt_request = HTTP::Request->new('POST', $plugin_config{apiEndpoint}, $headers, $alt_json);
                my $alt_response = $ua->request($alt_request);

                message "[dynamicResponse] Alternative format response: " . $alt_response->status_line . "\n", "success";
                message "[dynamicResponse] Alternative format content:\n" . $alt_response->content . "\n", "success";

                if (!$alt_response->is_success) {
                    error "[dynamicResponse] Both test formats failed. API may not be compatible.\n";
                } else {
                    message "[dynamicResponse] Alternative format successful! Will use this format.\n", "success";
                    # Set a flag to use alternative format (we'll implement this later)
                }
            }
        } else {
            message "[dynamicResponse] API connection test successful!\n", "success";
        }
    };
    if ($@) {
        error "[dynamicResponse] Error during API connection test: $@\n";
    }
}

# Function to generate a response from OpenAI
sub generateResponse {
    my ($user, $message) = @_;

    # These modules should already be loaded in onStart,
    # but let's double-check to be safe
    unless ($has_required_modules) {
        error "[dynamicResponse] Required modules not available\n";
        return undef;
    }

    # Make sure JSON::Tiny is loaded
    unless (defined &encode_json && defined &decode_json) {
        error "[dynamicResponse] JSON functions not available\n";
        return undef;
    }

    my $messages = buildConversationMessages($user, $message);

    # Ensure model name is properly trimmed
    my $model_name = $plugin_config{model};
    $model_name =~ s/[\r\n\t\s]+$//g;
    $model_name =~ s/^[\r\n\t\s]+//g;

    my $data = {
        model => $model_name,
        messages => $messages,
        max_tokens => int($plugin_config{maxTokens}),
        temperature => $plugin_config{temperature} + 0.0,
    };

    # Log the data structure before encoding
    message "[dynamicResponse] API Request Data Structure:\n", "success";
    message "[dynamicResponse] - model: $plugin_config{model}\n", "success";
    message "[dynamicResponse] - max_tokens: " . int($plugin_config{maxTokens}) . "\n", "success";
    message "[dynamicResponse] - temperature: " . ($plugin_config{temperature} + 0.0) . "\n", "success";
    message "[dynamicResponse] - messages count: " . scalar(@$messages) . "\n", "success";

    # Log a few sample messages if they exist
    if (scalar(@$messages) > 0) {
        message "[dynamicResponse] - First message (role: $messages->[0]->{role}): " .
                substr($messages->[0]->{content}, 0, 50) . "...\n", "success";
    }
    if (scalar(@$messages) > 1) {
        message "[dynamicResponse] - Last message (role: $messages->[-1]->{role}): " .
                substr($messages->[-1]->{content}, 0, 50) . "...\n", "success";
    }

    my $json;
    eval {
        # Create a deep copy to encode for JSON without modifying original data
        my $data_for_json = dclone($data);

        # Encode string values within the messages array to UTF-8 bytes
        if (ref($data_for_json->{messages}) eq 'ARRAY') {
            foreach my $msg (@{$data_for_json->{messages}}) {
                if (ref($msg) eq 'HASH') {
                    foreach my $key (keys %$msg) {
                        # Check if it's a defined scalar string before encoding
                        if (defined $msg->{$key} && !ref($msg->{$key})) {
                             eval { $msg->{$key} = Encode::encode_utf8($msg->{$key}); };
                             if ($@) {
                                 warning "[dynamicResponse] Failed to encode message key '$key' to UTF-8: $@\n";
                             }
                        }
                    }
                }
            }
        }
        # Encode the model name if it's a string
        if (exists $data_for_json->{model} && defined $data_for_json->{model} && !ref($data_for_json->{model})) {
            eval { $data_for_json->{model} = Encode::encode_utf8($data_for_json->{model}); };
             if ($@) {
                 warning "[dynamicResponse] Failed to encode model name to UTF-8: $@\n";
             }
        }

        # Encode the JSON using the UTF-8 encoded data structure
        $json = encode_json($data_for_json);
    };
    if ($@) {
        error "[dynamicResponse] Error encoding JSON: $@\n";
        # Add more context to the error message
        error "[dynamicResponse] Data structure that failed to encode (first level keys): " . join(", ", keys %$data) . "\n";
        if (ref($data->{messages}) eq 'ARRAY') {
            error "[dynamicResponse] Number of messages: " . scalar(@{$data->{messages}}) . "\n";
        }
        return undef;
    }

    # Log the complete JSON payload
    message "[dynamicResponse] Complete JSON payload:\n$json\n", "success";

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);

    my $headers = HTTP::Headers->new(
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer $plugin_config{apiKey}"
    );

    my $request = HTTP::Request->new('POST', $plugin_config{apiEndpoint}, $headers, $json);

    message "[dynamicResponse] Sending request to API endpoint: $plugin_config{apiEndpoint}\n", "success";
    message "[dynamicResponse] Request headers: Content-Type: application/json, Authorization: Bearer [REDACTED]\n", "success";

    my $response;
    eval {
        $response = $ua->request($request);
    };
    if ($@) {
        error "[dynamicResponse] Error making API request: $@\n";
        return undef;
    }

    # Log response details regardless of success or failure
    if ($response) {
        message "[dynamicResponse] API response status: " . $response->status_line . "\n", "success";
        message "[dynamicResponse] API response headers:\n", "success";
        foreach my $header ($response->header_field_names) {
            message "[dynamicResponse]   $header: " . $response->header($header) . "\n", "success";
        }
        message "[dynamicResponse] API response content:\n" . $response->content . "\n", "success";
    } else {
        error "[dynamicResponse] Received no response from API\n";
        return undef;
    }

    if (!$response->is_success) {
        error "[dynamicResponse] API request failed: " . $response->status_line . "\n";
        # Additional debug info for a 400 error
        if ($response->code == 400) {
            error "[dynamicResponse] Bad Request (400) details: " . $response->content . "\n";
            error "[dynamicResponse] This usually indicates a problem with the request format\n";
        }
        return undef;
    }

    my $content;
    eval {
        $content = decode_json($response->content);
    };
    if ($@) {
        error "[dynamicResponse] Error parsing JSON response: $@\n";
        return undef;
    }

    # Check different possible response formats and extract the reply
    my $reply;

    # First try OpenAI format
    eval {
        if ($content && exists $content->{choices} && defined $content->{choices}[0]) {
            if (exists $content->{choices}[0]{message} && exists $content->{choices}[0]{message}{content}) {
                # Standard OpenAI format
                $reply = $content->{choices}[0]{message}{content};
                message "[dynamicResponse] Found reply in OpenAI format\n", "success";
            }
            elsif (exists $content->{choices}[0]{text}) {
                # Some models return a simple text field
                $reply = $content->{choices}[0]{text};
                message "[dynamicResponse] Found reply in 'text' field\n", "success";
            }
        }
        # Try Ollama format
        elsif ($content && exists $content->{response}) {
            $reply = $content->{response};
            message "[dynamicResponse] Found reply in Ollama format (response field)\n", "success";
        }
        # Try older completion format
        elsif ($content && exists $content->{text}) {
            $reply = $content->{text};
            message "[dynamicResponse] Found reply in text field (completion format)\n", "success";
        }
    };
    if ($@) {
        error "[dynamicResponse] Error extracting reply from response: $@\n";
    }

    # Check if we failed to extract a reply
    if (!defined $reply || $reply eq '') {
        error "[dynamicResponse] Invalid API response structure or empty reply\n";
        error "[dynamicResponse] Response content: " . $response->content . "\n";

        # Try an alternative format if the standard format failed
        if (!$use_alternative_format) {
            message "[dynamicResponse] Trying alternative format...\n", "success";

            # Build a simple prompt by concatenating system + user message
            my $prompt = $plugin_config{personality} . "\n\n";
            $prompt .= "User: $message\n";
            $prompt .= "Reply: ";

            # Create alternative data structure
            my $alt_data = {
                model => $model_name,  # Use trimmed model name here too
                prompt => $prompt,
                max_tokens => int($plugin_config{maxTokens}),
                temperature => $plugin_config{temperature} + 0.0,
            };

            my $alt_json = encode_json($alt_data);
            my $alt_request = HTTP::Request->new('POST', $plugin_config{apiEndpoint}, $headers, $alt_json);

            message "[dynamicResponse] Sending alternative format request\n", "success";
            message "[dynamicResponse] Alternative payload:\n$alt_json\n", "success";

            my $alt_response = $ua->request($alt_request);

            if ($alt_response->is_success) {
                message "[dynamicResponse] Alternative format successful!\n", "success";
                message "[dynamicResponse] Response: " . $alt_response->content . "\n", "success";

                # Try to extract reply from alternative format
                eval {
                    my $alt_content = decode_json($alt_response->content);
                    if ($alt_content && exists $alt_content->{choices} && defined $alt_content->{choices}[0]) {
                        if (exists $alt_content->{choices}[0]{text}) {
                            $reply = $alt_content->{choices}[0]{text};
                        }
                    }
                    elsif ($alt_content && exists $alt_content->{response}) {
                        $reply = $alt_content->{response};
                    }
                    elsif ($alt_content && exists $alt_content->{text}) {
                        $reply = $alt_content->{text};
                    }
                };
                if ($@) {
                    error "[dynamicResponse] Error extracting reply from alternative response: $@\n";
                }
            }
        }

        # If we still don't have a reply, return undef
        if (!defined $reply || $reply eq '') {
            error "[dynamicResponse] Failed to extract reply from all response formats\n";
            return undef;
        }
    }

    # Clean up the response
    $reply =~ s/<think>.*?<\/think>//gs; # Remove <think> tags and content
    $reply =~ s/^\s+|\s+$//g;  # Trim whitespace

    # Log the response if enabled
    if ($plugin_config{logResponses}) {
        message "[dynamicResponse] User: $user, Message: $message, Response: $reply\n", "dynamicResponse";
    }

    # Update conversation history
    updateHistory($user, $message, $reply);

    return $reply;
}

1;
