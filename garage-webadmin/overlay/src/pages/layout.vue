<script lang="ts">
import { defineBasicLoader } from "vue-router/experimental"
import { client } from "../store.ts"
import { HttpError, successOrThrow } from "../utils/api.ts"

export const useGetClusterLayout = defineBasicLoader(async () => successOrThrow(await client.GET("/v2/GetClusterLayout")), {
	errors: [HttpError, Error],
})

export const useGetClusterStatus = defineBasicLoader(async () => successOrThrow(await client.GET("/v2/GetClusterStatus")), {
	errors: [HttpError, Error],
})
</script>

<script lang="ts" setup>
import { computed, ref } from "vue"
import LayoutDefault from "../components/layouts/Default.vue"
import BannerError from "../components/BannerError.vue"
import Banner from "../components/Banner.vue"
import Modal from "../components/Modal.vue"
import { formatBytes, shortId } from "../utils/labels.ts"
import { PhArrowsCounterClockwise, PhCheck, PhX, PhWarning } from "@phosphor-icons/vue"

const { data: layout, isLoading: layoutLoading, error: layoutError, reload: layoutReload } = useGetClusterLayout()
const { data: status, isLoading: statusLoading, error: statusError, reload: statusReload } = useGetClusterStatus()

function reloadAll() {
	layoutReload()
	statusReload()
}

const isLoading = computed(() => layoutLoading.value || statusLoading.value)

const hostnameMap = computed(() => {
	if (!status.value) return {} as Record<string, string>
	return Object.fromEntries(status.value.nodes.map((n) => [n.id, n.hostname ?? n.id]))
})

const roles = computed(() => {
	if (!layout.value) return []
	return layout.value.roles.map((r) => ({
		...r,
		hostname: hostnameMap.value[r.id] ?? shortId(r.id, "small"),
		isGateway: r.capacity == null,
	}))
})

const stagedChanges = computed(() => layout.value?.stagedRoleChanges ?? [])
const hasStagedChanges = computed(() => stagedChanges.value.length > 0)

const previewLoading = ref(false)
const previewResult = ref<{ message: string[]; newVersion: number } | null>(null)
const previewError = ref<string | null>(null)

async function runPreview() {
	previewLoading.value = true
	previewResult.value = null
	previewError.value = null
	try {
		const res = await client.POST("/v2/PreviewClusterLayoutChanges", { body: {} })
		if (res.error) throw new Error(String(res.error))
		const data = res.data as any
		if (data.error) {
			previewError.value = data.error
		} else {
			previewResult.value = { message: data.message ?? [], newVersion: data.newLayout?.version ?? 0 }
		}
	} catch (e) {
		previewError.value = (e as Error).message
	} finally {
		previewLoading.value = false
	}
}

const applyLoading = ref(false)
const applyError = ref<Error | null>(null)

async function runApply() {
	if (!layout.value) return
	applyLoading.value = true
	applyError.value = null
	try {
		const res = await client.POST("/v2/ApplyClusterLayout", {
			body: { version: layout.value.version + 1 },
		})
		if (res.error) throw new Error(String(res.error))
		reloadAll()
	} catch (e) {
		applyError.value = e as Error
	} finally {
		applyLoading.value = false
	}
}

const revertLoading = ref(false)
const revertError = ref<Error | null>(null)

async function runRevert() {
	revertLoading.value = true
	revertError.value = null
	try {
		const res = await client.POST("/v2/RevertClusterLayout", { body: {} })
		if (res.error) throw new Error(String(res.error))
		reloadAll()
	} catch (e) {
		revertError.value = e as Error
	} finally {
		revertLoading.value = false
	}
}
</script>

<template>
	<LayoutDefault>
		<div class="sectionHeader">
			<div class="sectionHeader-content">
				<h1 class="title title-1">Layout</h1>
			</div>
			<div class="sectionHeader-side">
				<button class="btn" :class="{ 'btn--loading': isLoading }" @click="reloadAll">
					<PhArrowsCounterClockwise :size="20" weight="bold" />Refresh
				</button>
			</div>
		</div>

		<BannerError v-if="layoutError" :error="layoutError" id="api_error_layout" />
		<BannerError v-if="statusError" :error="statusError" id="api_error_status" />

		<div class="flex flex-column gap gap--12" v-if="layout">
			<!-- Layout summary -->
			<dl class="summary">
				<div class="summary-cell">
					<dt class="summary-label">Layout version</dt>
					<dd class="summary-detail">{{ layout.version }}</dd>
				</div>
				<div class="summary-cell">
					<dt class="summary-label">Partition size</dt>
					<dd class="summary-detail">
						{{ formatBytes(layout.partitionSize).value }}&ThinSpace;
						<span class="color-gray text-normal">{{ formatBytes(layout.partitionSize).unit }}</span>
					</dd>
				</div>
				<div class="summary-cell">
					<dt class="summary-label">Zone redundancy</dt>
					<dd class="summary-detail">{{ layout.parameters.zoneRedundancy }}</dd>
				</div>
				<div class="summary-cell">
					<dt class="summary-label">Storage nodes</dt>
					<dd class="summary-detail">{{ roles.filter((r) => !r.isGateway).length }}</dd>
				</div>
			</dl>

			<!-- Staged changes banner -->
			<Banner v-if="hasStagedChanges" type="warning" icon>
				{{ stagedChanges.length }} staged {{ stagedChanges.length === 1 ? "change" : "changes" }} pending —
				preview and apply or revert below.
			</Banner>

			<!-- Current node roles -->
			<div class="flex flex-column gap gap--12">
				<h2 class="title title-2">Node Roles</h2>
				<div v-if="roles.length === 0" class="card color-gray text-small">No nodes are assigned to the layout yet.</div>
				<template v-else>
					<div v-for="role in roles" :key="role.id" class="card flex flex-wrap justify-between items-center gap">
						<div class="flex flex-column gap">
							<div class="flex flex-wrap items-center gap gap--8">
								<span class="tag tag--small color-gray text-uppercase text-monospace tabular-nums" :title="role.id">
									{{ shortId(role.id, "tiny") }}
								</span>
								<span class="text-semibold">{{ role.hostname }}</span>
								<span class="tag tag--small" v-if="role.isGateway">gateway</span>
							</div>
							<div class="flex flex-wrap gap gap--8 text-small color-gray">
								<span>Zone: <span class="color-text">{{ role.zone }}</span></span>
								<span v-if="role.tags.length > 0">Tags: <span class="color-text">{{ role.tags.join(", ") }}</span></span>
							</div>
						</div>
						<div class="flex flex-column gap items-end text-small color-gray">
							<span v-if="!role.isGateway">
								{{ formatBytes(role.capacity!).value }}&ThinSpace;{{ formatBytes(role.capacity!).unit }}
							</span>
							<span v-if="role.storedPartitions != null">
								{{ role.storedPartitions }} partition{{ role.storedPartitions === 1 ? "" : "s" }}
							</span>
						</div>
					</div>
				</template>
			</div>

			<!-- Staged changes detail -->
			<div class="flex flex-column gap gap--12" v-if="hasStagedChanges">
				<h2 class="title title-2">Staged Changes</h2>

				<div v-for="change in stagedChanges" :key="change.id" class="card flex flex-wrap justify-between items-center gap">
					<div class="flex flex-wrap items-center gap gap--8">
						<span class="tag tag--small color-gray text-uppercase text-monospace tabular-nums" :title="change.id">
							{{ shortId(change.id, "tiny") }}
						</span>
						<span class="text-semibold">{{ hostnameMap[change.id] ?? shortId(change.id, "small") }}</span>
					</div>
					<span v-if="(change as any).remove" class="tag tag--small tag--red">remove</span>
					<div v-else class="flex flex-wrap gap gap--8 text-small color-gray">
						<span v-if="(change as any).zone">Zone: <span class="color-text">{{ (change as any).zone }}</span></span>
						<span v-if="(change as any).capacity != null">
							{{ formatBytes((change as any).capacity).value }}&ThinSpace;{{ formatBytes((change as any).capacity).unit }}
						</span>
					</div>
				</div>

				<!-- Preview output -->
				<div v-if="previewResult" class="card flex flex-column gap text-small">
					<div class="text-semibold">Preview — new layout version {{ previewResult.newVersion }}</div>
					<pre class="color-gray" style="white-space: pre-wrap; word-break: break-word">{{ previewResult.message.join("\n") }}</pre>
				</div>
				<Banner v-if="previewError" type="error" icon>{{ previewError }}</Banner>
				<BannerError v-if="applyError" :error="applyError" id="apply_error" />
				<BannerError v-if="revertError" :error="revertError" id="revert_error" />

				<div class="flex flex-wrap gap">
					<button class="btn" :class="{ 'btn--loading': previewLoading }" @click="runPreview">
						Preview changes
					</button>
					<button
						class="btn btn--primary"
						:class="{ 'btn--loading': applyLoading }"
						command="show-modal"
						commandfor="apply_layout_modal"
					>
						Apply layout
					</button>
					<button class="btn" :class="{ 'btn--loading': revertLoading }" @click="runRevert">
						Revert staged changes
					</button>
				</div>

				<Modal id="apply_layout_modal" title="Apply layout" closedby="any">
					<Banner type="warning" icon>
						This will apply the staged changes and advance the layout to version {{ layout.version + 1 }}.
						All nodes will redistribute data according to the new layout.
					</Banner>
					<div class="flex gap mt20">
						<button
							class="btn btn--primary flex-grow"
							:class="{ 'btn--loading': applyLoading }"
							@click="runApply"
							command="close"
							commandfor="apply_layout_modal"
						>
							<PhCheck :size="20" weight="bold" />Apply
						</button>
						<button class="btn flex-grow" command="close" commandfor="apply_layout_modal">
							<PhX :size="20" weight="bold" />Cancel
						</button>
					</div>
				</Modal>
			</div>
		</div>
	</LayoutDefault>
</template>
