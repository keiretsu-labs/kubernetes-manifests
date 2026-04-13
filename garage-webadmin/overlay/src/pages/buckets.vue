<script lang="ts">
import { defineBasicLoader } from "vue-router/experimental"
import { client } from "../store.ts"
import { HttpError, successOrThrow } from "../utils/api.ts"

export const useListBuckets = defineBasicLoader(async () => successOrThrow(await client.GET("/v2/ListBuckets")), {
	errors: [HttpError, Error],
})
</script>

<script lang="ts" setup>
import LayoutDefault from "../components/layouts/Default.vue"
import EmptyState from "../components/EmptyState.vue"
import BannerError from "../components/BannerError.vue"
import { shortId } from "../utils/labels.ts"
import { PhArrowsCounterClockwise } from "@phosphor-icons/vue"

const { data: buckets, isLoading, error, reload } = useListBuckets()
</script>

<template>
	<LayoutDefault>
		<div class="sectionHeader">
			<div class="sectionHeader-content">
				<h1 class="title title-1">Buckets</h1>
			</div>
			<div class="sectionHeader-side">
				<button class="btn" :class="{ 'btn--loading': isLoading }" @click="reload">
					<PhArrowsCounterClockwise :size="20" weight="bold" />Refresh
				</button>
			</div>
		</div>

		<BannerError v-if="error" :error="error" id="api_error_buckets" />

		<div class="flex flex-column gap gap--12" v-if="!error">
			<div class="card flex flex-wrap justify-between items-center gap">
				{{ buckets?.length ?? "-" }} {{ (buckets?.length ?? 0) === 1 ? "bucket" : "buckets" }}
			</div>

			<template v-for="bucket in buckets" :key="bucket.id">
				<div class="card flex flex-wrap justify-between items-center gap">
					<div class="flex flex-column gap">
						<div class="flex flex-wrap items-center gap gap--8">
							<span class="tag tag--small color-gray text-uppercase text-monospace tabular-nums" :title="bucket.id">
								{{ shortId(bucket.id, "tiny") }}
							</span>
							<span class="text-semibold" v-if="bucket.globalAliases.length > 0">{{ bucket.globalAliases.join(", ") }}</span>
							<span class="color-gray" v-else>(no global alias)</span>
						</div>
						<div class="text-small color-gray" v-if="bucket.created">
							Created {{ new Date(bucket.created).toLocaleDateString() }}
						</div>
					</div>
					<div class="text-small color-gray" v-if="bucket.localAliases.length > 0">
						{{ bucket.localAliases.length }} local {{ bucket.localAliases.length === 1 ? "alias" : "aliases" }}
					</div>
				</div>
			</template>

			<div v-if="buckets?.length === 0" class="cardLink cardLink--disabled flex justify-center">
				<div class="flex flex-column items-center justify-center mt12 mb12">
					<EmptyState title="No Buckets" subtitle="No storage buckets have been created yet" />
				</div>
			</div>
		</div>
	</LayoutDefault>
</template>
