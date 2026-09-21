require 'xcodeproj'
project_path = 'Relyvo.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

group = project.main_group.find_subpath(File.join('Relyvo', 'Services'), true)
file_ref = group.new_reference('ChannelAccessGate.swift')
target.source_build_phase.add_file_reference(file_ref)

project.save
