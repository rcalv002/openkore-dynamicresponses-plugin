package dynamicResponse_simple;

use strict;
use warnings;
use Plugins;
use Settings;
use Globals qw($messageSender $char %config);
use Log qw(message warning error debug);

# Plugin hook registration
Plugins::register("dynamicResponse_simple", "Simple test for chat responses", \&onUnload);
my $hooks = Plugins::addHooks(
    ['ChatQueue::processChatResponse', \&onChatResponse, undef],
    ['start3', \&onStart, undef],
    # Add a hook for AI_pre to show periodic debug info
    ['AI_pre', \&onAI_pre, undef],
);

# Flag to control whether to use direct messaging (faster) or built-in system
my $use_direct_messaging = 1;

my $initialized = 0;
my $message_counter = 0;

# Plugin initialization
sub onStart {
    message "[dynamicResponse_simple] Plugin initialized - Version 2.0 (Debug)\n", "success";
    message "[dynamicResponse_simple] Waiting for chat messages containing 'test'...\n", "success";
    $initialized = 1;
}

# Add a periodic check to confirm plugin is running
sub onAI_pre {
    return unless $initialized;

    # Every 100 AI cycles (approximately every few seconds)
    if ($message_counter % 100 == 0) {
        debug "[dynamicResponse_simple] Plugin is active and waiting for messages. Counter: $message_counter\n", "plugin";
    }
    $message_counter++;
}

# Unload function
sub onUnload {
    Plugins::delHooks($hooks);
    message "[dynamicResponse_simple] Plugin unloaded\n", "success";
}

# Chat response hook callback
sub onChatResponse {
    my ($hook, $args) = @_;

    # Log that we received a chat message event
    message "[dynamicResponse_simple] Message event received.\n", "success";

    # Check if args are defined
    if (!defined $args) {
        error "[dynamicResponse_simple] ERROR: args not defined!\n";
        return;
    }

    # Check if msg is defined
    if (!defined $args->{msg}) {
        error "[dynamicResponse_simple] ERROR: args->{msg} not defined!\n";
        return;
    }

    # Check if char is defined
    if (!defined $char) {
        error "[dynamicResponse_simple] ERROR: char not defined!\n";
        return;
    }

    # Check if char name is defined
    if (!defined $char->{name}) {
        error "[dynamicResponse_simple] ERROR: char->{name} not defined!\n";
        return;
    }

    my $msg = $args->{msg};
    my $user = $args->{user} || "Unknown";
    my $type = $args->{type} || "unknown";

    # Log every message that comes through
    message "[dynamicResponse_simple] Received message: '$msg' from user '$user', type: '$type'\n", "success";

    # Don't process our own messages
    if ($user eq $char->{name}) {
        message "[dynamicResponse_simple] Skipping our own message.\n", "success";
        return;
    }

    # If message contains "test", reply with a simple test message
    if ($msg =~ /test/i) {
        message "[dynamicResponse_simple] TEST KEYWORD DETECTED! Responding...\n", "success";
        my $response = "This is a test response from the simple plugin.";

        if ($use_direct_messaging && $messageSender && $type) {
            # Send message directly without delay
            message "[dynamicResponse_simple] Sending response directly: '$response'\n", "success";
            sendMessage($messageSender, $type, $response, $user);
            $args->{return} = 1;  # Prevent further processing
        } else {
            # Use the traditional method with built-in delay
            message "[dynamicResponse_simple] Using built-in response system: '$response'\n", "success";
            $args->{reply} = $response;
            $args->{return} = 1;
        }

        message "[dynamicResponse_simple] Set reply to: '$response'\n", "success";
    } else {
        message "[dynamicResponse_simple] No test keyword in message.\n", "success";
    }

    # Also debug if we received the built-in command handling
    if ($config{autoResponse}) {
        message "[dynamicResponse_simple] AutoResponse is enabled in config.\n", "success";
    } else {
        message "[dynamicResponse_simple] WARNING: AutoResponse is disabled in config!\n", "success";
    }
}

# Helper function to send a message directly
sub sendMessage {
    my ($messageSender, $type, $message, $user) = @_;

    if (!defined $messageSender) {
        error "[dynamicResponse_simple] MessageSender not defined\n";
        return;
    }

    my $type_code = '';

    # Convert type to the correct code
    if ($type eq 'c') {
        # Public chat
        $messageSender->sendChat($message);
        message "[dynamicResponse_simple] Sent public chat: $message\n", "success";
    } elsif ($type eq 'pm') {
        # Private message
        $messageSender->sendPrivateMsg($user, $message);
        message "[dynamicResponse_simple] Sent PM to $user: $message\n", "success";
    } elsif ($type eq 'p') {
        # Party chat
        $messageSender->sendPartyChat($message);
        message "[dynamicResponse_simple] Sent party chat: $message\n", "success";
    } elsif ($type eq 'g') {
        # Guild chat
        $messageSender->sendGuildChat($message);
        message "[dynamicResponse_simple] Sent guild chat: $message\n", "success";
    } else {
        error "[dynamicResponse_simple] Unknown chat type: $type\n";
    }
}
