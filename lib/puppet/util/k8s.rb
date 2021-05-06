# frozen_string_literal: true

module Puppet::Util
  # Utility methods for K8s
  module K8s
    def self.content_diff(local, content)
      delete_merge = proc do |hash1, hash2|
        hash2.each_pair do |key, value|
          if hash1[key] != hash1[key.to_s]
            hash1[key.to_s] = hash1.delete key
            key = key.to_s
          end

          target_value = hash1[key]
          if target_value.is_a?(Hash) && value.is_a?(Hash) && value.any? && target_value.any?
            delete_merge.call(target_value, value)
          elsif value.is_a?(Array) && target_value.is_a?(Array) && value.any? && target_value.any?
            diff = value.size != target_value.size
            target_value.each do |v|
              break if diff
              next if value.include? v

              if v.is_a? Hash
                diff ||= !value.select { |ov| ov.is_a? Hash }.any? do |ov|
                  v_copy = Marshal.load(Marshal.dump(v))
                  delete_merge.call(v_copy, ov)

                  v_copy.empty?
                end
              else
                diff = true
              end
            end

            hash1.delete(key) unless diff
          elsif hash1.key?(key) && target_value == value
            hash1.delete(key)
          end
          hash1.delete(key) if hash1.key?(key) && (hash1[key].nil? || hash1[key].empty?)
        end

        hash1
      end

      # Verify that the intersection of upstream content and user-provided content is identical
      # This allows the upstream object to contain additional keys - such as those auto-generated by Kubernetes
      diff = Marshal.load(Marshal.dump(local))
      delete_merge.call(diff, content)

      diff
    end
  end
end
