require 'xcodeproj'
project_path = 'LocalAI.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'LocalAI' }

# Find or create the main group reference
main_group = project.main_group.groups.find { |g| g.name == 'LocalAI' } || project.main_group

# Check if espeak-ng-data is already added
unless main_group.children.find { |c| c.name == 'espeak-ng-data' }
  # Add as folder reference (last argument true or just use new_reference and set lastKnownFileType)
  file_ref = main_group.new_reference('LocalAI/espeak-ng-data')
  file_ref.last_known_file_type = 'folder'
  
  # Add to Resources Build Phase
  resources_phase = target.resources_build_phase
  build_file = resources_phase.add_file_reference(file_ref)
  puts "Added espeak-ng-data to Xcode project."
end

project.save
