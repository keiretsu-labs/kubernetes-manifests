<script lang="ts">
import { defineBasicLoader } from "vue-router/experimental"
import { client } from "../store.ts"
import { HttpError, successOrThrow } from "../utils/api.ts"

export const useListKeys = defineBasicLoader(async () => successOrThrow(await client.GET("/v2/ListKeys")), {
	errors: [HttpError, Error],
})
</script>

<script lang="ts" setup>
import LayoutDefault from "../components/layouts/Default.vue"
import EmptyState from "../components/EmptyState.vue"
import BannerError from "../components/BannerError.vue"
import { PhArrowsCounterClockwise } from "@phosphor-icons/vue"

const { data: keys, isLoading, error, reload } = useListKeys()
</script>

<template>
	<LayoutDefault>
		<div class="sectionHeader">
			<div class="sectionHeader-content">
				<h1 class="title title-1">Access Keys</h1>
			</div>
			<div class="sectionHeader-side">
				<button class="btn" :class="{ 'btn--loading': isLoading }" @click="reload">
					<PhArrowsCounterClockwise :size="20" weight="bold" />Refresh
				</button>
			</div>
		</div>

		<BannerError v-if="error" :error="error" id="api_error_keys" />

		<div class="flex flex-column gap gap--12" v-if="!error">
			<div class="card flex flex-wrap justify-between items-center gap">
				{{ keys?.filter((k) => !k.expired).length ?? "-" }} active
				<span class="color-gray text-small">of {{ keys?.length ?? "-" }} total</span>
			</div>

			<template v-for="key in keys" :key="key.id">
				<div class="card flex flex-wrap justify-between items-center gap">
					<div class="flex flex-column gap">
						<div class="text-semibold text-monospace">{{ key.id }}</div>
						<div class="color-gray text-small" v-if="key.name">{{ key.name }}</div>
						<div class="text-small color-gray" v-if="key.created">
							Created {{ new Date(key.created).toLocaleDateString() }}
						</div>
					</div>
					<div class="flex flex-wrap gap gap--8 items-center text-small">
						<span class="tag tag--small" :class="key.expired ? 'tag--red' : 'tag--green'">
							{{ key.expired ? "Expired" : "Active" }}
						</span>
						<span class="color-gray" v-if="key.expiration && !key.expired">
							Expires {{ new Date(key.expiration).toLocaleDateString() }}
						</span>
					</div>
				</div>
			</template>

			<div v-if="keys?.length === 0" class="cardLink cardLink--disabled flex justify-center">
				<div class="flex flex-column items-center justify-center mt12 mb12">
					<EmptyState title="No Access Keys" subtitle="No access keys have been created yet" />
				</div>
			</div>
		</div>
	</LayoutDefault>
</template>
