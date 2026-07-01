require 'xcodeproj'

project_path = 'LocalAI.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Ensure packages exist in root object package references
['FluxSwiftLocal', 'KokoroSwiftLocal', 'MisakiSwiftLocal'].each do |pkg|
  ref_path = "Packages/#{pkg}"
  package_ref = project.root_object.package_references.find { |pr| pr.class == Xcodeproj::Project::Object::XCLocalSwiftPackageReference && pr.relative_path == ref_path }
  if package_ref.nil?
    package_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    package_ref.relative_path = ref_path
    project.root_object.package_references << package_ref
    puts "Added package reference for #{pkg}"
  end
end

target = project.targets.find { |t| t.name == 'LocalAI' }

# Add dependencies
{'FluxSwift' => 'FluxSwiftLocal', 'KokoroSwift' => 'KokoroSwiftLocal', 'MisakiSwift' => 'MisakiSwiftLocal'}.each do |product_name, pkg_name|
  package_dep = target.package_product_dependencies.find { |pd| pd.product_name == product_name }
  if package_dep.nil?
    package_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    package_dep.product_name = product_name
    target.package_product_dependencies << package_dep
    puts "Added package dependency for #{product_name}"
    
    # Also add to framework build phase
    frameworks_phase = target.frameworks_build_phase
    build_file = frameworks_phase.files.find { |bf| bf.product_ref == package_dep }
    if build_file.nil?
      build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
      build_file.product_ref = package_dep
      frameworks_phase.files << build_file
      puts "Added #{product_name} to frameworks build phase"
    end
  end
end

project.save
puts "Successfully saved project."
