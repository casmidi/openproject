#-- copyright
#++

module Storages
  class AutomaticallyManagedStorageSyncJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    SINGLE_THREAD_DEBOUNCE_TIME = 4.seconds
    class << self
      def debounce(storage)
        key = "sync-#{storage.short_provider_type}-#{storage.id}"
        timestamp = RequestStore.store[key]

        return false if timestamp.present? && (timestamp + SINGLE_THREAD_DEBOUNCE_TIME) > Time.current

        result = set(wait: 5.seconds).perform_later(storage)
        RequestStore.store[key] = Time.current
        result
      end
    end

    good_job_control_concurrency_with(
      total_limit: 2,
      enqueue_limit: 1,
      perform_limit: 1,
      key: -> { "StorageSyncJob-#{arguments.last.short_provider_type}-#{arguments.last.id}" }
    )

    retry_on GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError, wait: 5, attempts: 10

    retry_on Errors::IntegrationJobError, attempts: 5 do |job, error|
      if job.executions >= 5
        OpenProject::Notifications.send(
          OpenProject::Events::STORAGE_TURNED_UNHEALTHY, storage: job.arguments.last, reason: error.message
        )
      end
    end

    def perform(storage)
      return unless storage.configured? && storage.automatically_managed?

      sync_result = case storage.short_provider_type
                    when "nextcloud"
                      NextcloudGroupFolderPropertiesSyncService.call(storage)
                    when "one_drive"
                      OneDriveManagedFolderSyncService.call(storage)
                    else
                      raise "Unknown Storage Type"
                    end

      sync_result.on_failure { raise Errors::IntegrationJobError, sync_result.errors.to_s }
      sync_result.on_success { OpenProject::Notifications.send(OpenProject::Events::STORAGE_TURNED_HEALTHY, storage:) }
    end
  end
end
