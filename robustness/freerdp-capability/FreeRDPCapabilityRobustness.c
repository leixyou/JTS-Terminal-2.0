#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/client.h>
#include <freerdp/peer.h>
#include <winpr/stream.h>
#include <winpr/wlog.h>

#include "capabilities.h"

#define JTS_MAXIMUM_CAPABILITY_INPUT (1024U * 1024U)
#define JTS_MAXIMUM_CAPABILITY_BODY UINT16_MAX

typedef struct
{
	const uint8_t* bytes;
	size_t size;
	uint8_t* allocation;
} JTSRobustnessInput;

static int jts_hex_nibble(uint8_t value)
{
	if ((value >= '0') && (value <= '9'))
		return value - '0';
	if ((value >= 'a') && (value <= 'f'))
		return value - 'a' + 10;
	if ((value >= 'A') && (value <= 'F'))
		return value - 'A' + 10;
	return -1;
}

static JTSRobustnessInput jts_decode_hex_envelope(const uint8_t* data, size_t size)
{
	JTSRobustnessInput result = { data, size, NULL };
	if (!data || (size < 4) || (memcmp(data, "hex:", 4) != 0))
		return result;

	size_t digitCount = 0;
	for (size_t index = 4; index < size; index++)
	{
		if (isspace((unsigned char)data[index]))
			continue;
		if (jts_hex_nibble(data[index]) < 0)
			return result;
		digitCount++;
	}
	if ((digitCount == 0) || ((digitCount % 2U) != 0))
		return result;

	uint8_t* decoded = calloc(digitCount / 2U, sizeof(uint8_t));
	if (!decoded)
		return result;

	size_t outputIndex = 0;
	int highNibble = -1;
	for (size_t index = 4; index < size; index++)
	{
		if (isspace((unsigned char)data[index]))
			continue;
		const int nibble = jts_hex_nibble(data[index]);
		if (highNibble < 0)
			highNibble = nibble;
		else
		{
			decoded[outputIndex++] = (uint8_t)((highNibble << 4) | nibble);
			highNibble = -1;
		}
	}

	result.bytes = decoded;
	result.size = outputIndex;
	result.allocation = decoded;
	return result;
}

static rdpContext* jts_new_client_context(void)
{
	RDP_CLIENT_ENTRY_POINTS entry = WINPR_C_ARRAY_INIT;
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(rdpContext);

	rdpContext* context = freerdp_client_context_new(&entry);
	if (context && context->rdp && context->rdp->log)
		WLog_SetLogLevel(context->rdp->log, WLOG_OFF);
	return context;
}

static freerdp_peer* jts_new_server_peer(void)
{
	freerdp_peer* peer = calloc(1, sizeof(freerdp_peer));
	if (!peer)
		return NULL;

	peer->ContextSize = sizeof(rdpContext);
	if (!freerdp_peer_context_new(peer))
	{
		free(peer);
		return NULL;
	}
	if (peer->context && peer->context->rdp && peer->context->rdp->log)
		WLog_SetLogLevel(peer->context->rdp->log, WLOG_OFF);
	return peer;
}

static void jts_free_server_peer(freerdp_peer* peer)
{
	if (!peer)
		return;
	freerdp_peer_context_free(peer);
	free(peer);
}

static void jts_exercise_all_capability_sets(const uint8_t* data, size_t size, BOOL isServer)
{
	rdpContext* client = NULL;
	freerdp_peer* peer = NULL;
	rdpRdp* rdp = NULL;

	if (isServer)
	{
		peer = jts_new_server_peer();
		rdp = (peer && peer->context) ? peer->context->rdp : NULL;
	}
	else
	{
		client = jts_new_client_context();
		rdp = client ? client->rdp : NULL;
	}

	if (rdp && rdp->settings)
	{
		const size_t bodySize = (size > JTS_MAXIMUM_CAPABILITY_BODY)
		                            ? JTS_MAXIMUM_CAPABILITY_BODY
		                            : size;
		for (UINT16 type = CAPSET_TYPE_GENERAL; type <= CAPSET_TYPE_FRAME_ACKNOWLEDGE; type++)
		{
			wStream buffer = WINPR_C_ARRAY_INIT;
			wStream* stream = Stream_StaticConstInit(&buffer, data, bodySize);
			if (stream)
				(void)rdp_read_capability_set(rdp->log, stream, type, rdp->settings, isServer);
		}
	}

	freerdp_client_context_free(client);
	jts_free_server_peer(peer);
}

static void jts_exercise_demand_active(const uint8_t* data, size_t size)
{
	rdpContext* context = jts_new_client_context();
	if (context && context->rdp)
	{
		const size_t boundedSize = (size > UINT16_MAX) ? UINT16_MAX : size;
		wStream buffer = WINPR_C_ARRAY_INIT;
		wStream* stream = Stream_StaticConstInit(&buffer, data, boundedSize);
		if (stream)
			(void)rdp_recv_demand_active(context->rdp, stream, 0, (UINT16)boundedSize);
	}
	freerdp_client_context_free(context);
}

static void jts_exercise_confirm_active(const uint8_t* data, size_t size)
{
	freerdp_peer* peer = jts_new_server_peer();
	if (peer && peer->context && peer->context->rdp)
	{
		const size_t boundedSize = (size > UINT16_MAX) ? UINT16_MAX : size;
		wStream buffer = WINPR_C_ARRAY_INIT;
		wStream* stream = Stream_StaticConstInit(&buffer, data, boundedSize);
		if (stream)
			(void)rdp_recv_confirm_active(peer->context->rdp, stream, (UINT16)boundedSize);
	}
	jts_free_server_peer(peer);
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	if (!data || (size == 0) || (size > JTS_MAXIMUM_CAPABILITY_INPUT))
		return 0;

	(void)WLog_SetLogLevel(WLog_GetRoot(), WLOG_OFF);

	JTSRobustnessInput input = jts_decode_hex_envelope(data, size);
	if (input.bytes && (input.size > 0))
	{
		/* Every input reaches every individual production capability-set reader
		 * in both client and server directions. The same bytes also enter the
		 * complete Demand Active and Confirm Active network PDU parsers with fresh
		 * contexts so state from one parser cannot mask a later failure. */
		jts_exercise_all_capability_sets(input.bytes, input.size, FALSE);
		jts_exercise_all_capability_sets(input.bytes, input.size, TRUE);
		jts_exercise_demand_active(input.bytes, input.size);
		jts_exercise_confirm_active(input.bytes, input.size);
	}

	free(input.allocation);
	return 0;
}
