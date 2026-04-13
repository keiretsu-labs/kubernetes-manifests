<script lang="ts">
import { defineBasicLoader } from "vue-router/experimental"
import { client } from "../store.ts"
import { HttpError, successOrThrow } from "../utils/api.ts"

export const useListAdminTokens = defineBasicLoader(async () => successOrThrow(await client.GET("/v2/ListAdminTokens")), {
	errors: [HttpError, Error],
})
</script>

<script lang="ts" setup>
import LayoutDefault from "../components/layouts/Default.vue"
import EmptyState from "../components/EmptyState.vue"
import BannerError from "../components/BannerError.vue"
import { shortId } from "../utils/labels.ts"
import { PhArrowsCounterClockwise } from "@phosphor-icons/vue"

const { data: tokens, isLoading, error, reload } = useListAdminTokens()
</script>

<template>
	<LayoutDefault>
		<div class="sectionHeader">
			<div class="sectionHeader-content">
				<h1 class="title title-1">Admin Tokens</h1>
			</div>
			<div class="sectionHeader-side">
				<button class="btn" :class="{ 'btn--loading': isLoading }" @click="reload">
					<PhArrowsCounterClockwise :size="20" weight="bold" />Refresh
				</button>
			</div>
		</div>

		<BannerError v-if="error" :error="error" id="api_error_tokens" />

		<div class="flex flex-column gap gap--12" v-if="!error">
			<div class="card flex flex-wrap justify-between items-center gap">
				{{ tokens?.filter((t) => !t.expired).length ?? "-" }} active
				<span class="color-gray text-small">of {{ tokens?.length ?? "-" }} total</span>
			</div>

			<template v-for="token in tokens" :key="token.id ?? token.name">
				<div class="card flex flex-wrap justify-between items-center gap">
					<div class="flex flex-column gap">
						<div class="flex flex-wrap items-center gap gap--8">
							<span
								v-if="token.id"
								class="tag tag--small color-gray text-uppercase text-monospace tabular-nums"
								:title="token.id"
							>
								{{ shortId(token.id, "small") }}
							</span>
							<span class="text-semibold">{{ token.name }}</span>
						</div>
						<div class="text-small color-gray" v-if="token.created">
							Created {{ new Date(token.created).toLocaleDateString() }}
						</div>
					</div>
					<div class="flex flex-wrap gap gap--8 items-center text-small">
						<span class="tag tag--small" :class="token.expired ? 'tag--red' : 'tag--green'">
							{{ token.expired ? "Expired" : "Active" }}
						</span>
						<span v-if="token.expiration && !token.expired" class="color-gray">
							Expires {{ new Date(token.expiration).toLocaleDateString() }}
						</span>
						<span v-if="token.scope.includes('*')" class="tag tag--small">All endpoints</span>
						<span v-else class="color-gray">{{ token.scope.length }} endpoint{{ token.scope.length === 1 ? "" : "s" }}</span>
					</div>
				</div>
			</template>

			<div v-if="tokens?.length === 0" class="cardLink cardLink--disabled flex justify-center">
				<div class="flex flex-column items-center justify-center mt12 mb12">
					<EmptyState title="No Admin Tokens" subtitle="No admin tokens have been created yet" />
				</div>
			</div>
		</div>
	</LayoutDefault>
</template>
