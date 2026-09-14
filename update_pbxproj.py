from pbxproj import XcodeProject

project = XcodeProject.load('Relyvo.xcodeproj/project.pbxproj')

files_to_add = [
    'Relyvo/Models/RoutingModels.swift',
    'Relyvo/Services/OfflineRoutingService.swift',
    'Relyvo/Services/RoutingDatabase.swift',
    'Relyvo/Utilities/RoutingTests.swift'
]

for file_path in files_to_add:
    # Adding to main group 'Relyvo'
    project.add_file(file_path, force=False)

project.save()
print("Added files to project")
