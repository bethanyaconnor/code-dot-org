module Services
  module I18n
    module CurriculumSyncUtils
      module SyncOut
        def self.run
          puts "Sync out curriculum content"
          reorganize
        end

        # The ScriptCrowdinSerializer used in the sync in organizes all content by
        # script; each script is a single file, containing all the individual
        # lessons, activities, etc, for the script. This works great for organizing
        # content in a way that can easily be worked on by translators, but for
        # rendering translations in model and view logic we're going to need to do
        # something different.
        #
        # Specifically, we want to flatten the complex files generated by the
        # sync in. Ultimately, we want one file per content type; one for all
        # lessons, one for all activities, one for all resources, etc.
        def self.reorganize
          Languages.get_locale.each do |prop|
            locale = prop[:locale_s]
            next if locale == 'en-US'
            locale_dir = File.join('i18n/locales', locale, 'curriculum_content')
            next unless File.directory?(locale_dir)

            # First we gather together all our script objects into a single hash
            script_objects = {}
            Dir.glob(File.join(locale_dir, '**/*.json')).each do |file|
              data = JSON.parse(File.read(file))
              name = File.basename(file)
              script_objects[name] = data if data.present?
            end

            # Then we recursively flatten all of our hashes of objects, to group them
            # by type rather than by script
            result = flatten(script_objects, Serializers::ScriptCrowdinSerializer, :scripts)

            # Then we apply some postprocessing.
            postprocess(result)

            # Finally, write each resulting collection of strings out to a rails i18n
            # config file.
            result.each do |type, strings|
              dest = File.join(Rails.root, 'config/locales', "#{type}.#{locale}.json")
              data = {locale => {data: {type => strings}}}
              File.write(dest, JSON.pretty_generate(data))
            end
          end
        end

        # Perform any necessary postprocessing to the final translated strings,
        # before writing them out to config files
        def self.postprocess(result)
          # We use URLs as keys for lessons in Crowdin, to make things easier for
          # translators. For the actual translation files, though, we'd like to use
          # more-standard keys.
          if result.key?(:lessons)
            rekeyed_lessons = result[:lessons].map do |lesson_url, lesson_data|
              route_params = Rails.application.routes.recognize_path(lesson_url)
              # Filter for only lessons which are "numbered".
              # Only these lessons guarantee that their relative position is unique.
              lessons = Lesson.joins(:script).
                where(
                  "scripts.name": route_params[:script_id],
                  relative_position: route_params[:position].to_i,
                ).select(&:numbered_lesson?)
              if lessons.count == 0
                STDERR.puts "Could not find lesson for url #{lesson_url.inspect}"
                next
              end
              if lessons.count > 1
                STDERR.puts "More than one lesson found for url #{lesson_url.inspect}. This should be investigated."
                next
              end
              lesson = lessons.first
              [Services::GloballyUniqueIdentifiers.build_lesson_key(lesson), lesson_data]
            end
            result[:lessons] = rekeyed_lessons.compact.to_h
          end

          # We also provide URLs to the translators for Resources only; because
          # the sync has a side effect of applying Markdown formatting to
          # everything it encounters, we want to make sure to un-Markdownify
          # these URLs
          if result.key?(:resources)
            result[:resources].each do |_key, resource|
              next unless resource[:url].present?
              resource[:url].strip!
              resource[:url].delete_prefix!('<')
              resource[:url].delete_suffix!('>')
            end
          end
        end

        # Given a deeply-nested hash of serialized objects (as generated by a
        # CrowdinCollectionSerializer) and a Serializer for the top-level object,
        # recursively extract all nested objects and return a flattened hash
        # organized by type.
        #
        # For example, given a hash of scripts like:
        #
        # {
        #   "coursea-2021": {
        #     "lessons": {
        #       "http://studio.code.org/s/coursea-2021/lessons/1": {
        #         "overview": "...",
        #         "preparation": "...",
        #         "purpose": "...",
        #         "student_overview": "...",
        #         "lesson_activities": {
        #           "09eb0525-dfae-44f2-831f-5c1f2ffee133": {
        #             "name": "...",
        #             "activity_sections": {
        #               "ef4f13d4-c5b0-4778-8ca1-359132023d82": {
        #                 "progression_name": "..."
        #               }
        #             }
        #           },
        #           ...
        #         },
        #         "resources": {
        #           "url": {
        #             "name": "..."
        #           },
        #         },
        #       },
        #       ...
        #     },
        #     "resources": {...}
        #   },
        #   "courseb-2021": {
        #     "lessons": {...}
        #     "resources": {...}
        #   },
        #   ...
        # }
        #
        # return:
        #
        # {
        #   "scripts": {
        #     "coursea-2021": {...},
        #     "courseb-2021": {...},
        #     ...
        #   },
        #   "lessons": {
        #     "http://studio.code.org/s/coursea-2021/lessons/1": {
        #       "overview": "...",
        #       "preparation": "...",
        #       "purpose": "...",
        #       "student_overview": "...",
        #     },
        #     "http://studio.code.org/s/courseb-2021/lessons/1": {...},
        #     ...
        #   },
        #   "lesson_activities": {
        #     "09eb0525-dfae-44f2-831f-5c1f2ffee133": {
        #       "name": "...",
        #     },
        #     ...
        #   },
        #   "activity_sections": {
        #     "ef4f13d4-c5b0-4778-8ca1-359132023d82": {
        #       "progression_name": "..."
        #     },
        #     ...
        #   },
        #   "resources": {
        #     "url": {
        #       "name": "..."
        #     },
        #     ...
        #   }
        # }
        def self.flatten(object_hash, serializer, name)
          results = {}
          object_hash.each do |key, object|
            object = object.symbolize_keys

            # store attributes directly on the results for this object
            attributes = object.slice(*serializer._attributes)
            if attributes.present?
              results[name] ||= {}
              results[name][key] = attributes
            end

            # recursively process "reflections" (ie, related model data) into their
            # own objects
            serializer._reflections.each do |reflection_key, reflection|
              next unless object.key?(reflection_key) && object[reflection_key].present?
              results.deep_merge!(flatten(object[reflection_key], reflection.options[:serializer], reflection.name))
            end
          end
          return results
        end
      end
    end
  end
end
