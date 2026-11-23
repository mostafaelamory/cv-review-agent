// Seeds a sample role with weighted requirements. Safe to re-run: skips an existing role with the same name.
String roleName = 'Senior Salesforce Developer';
if (![SELECT Id FROM Job_Role__c WHERE Name = :roleName].isEmpty()) {
    System.debug('SEED role already exists');
    return;
}
Job_Role__c role = new Job_Role__c(
    Name = roleName,
    Status__c = 'Open',
    Description__c = 'Senior developer for a Service Cloud programme: Apex and LWC delivery, integrations, ' +
        'code quality, and mentoring a small team.'
);
insert role;
insert new List<Role_Requirement__c>{
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Apex development (triggers, services, tests)', Type__c = 'Must-have', Category__c = 'Skill', Weight__c = 20, Keywords__c = 'apex'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Lightning Web Components', Type__c = 'Must-have', Category__c = 'Skill', Weight__c = 15, Keywords__c = 'lwc,lightning web components'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = '4+ years of Salesforce development', Type__c = 'Must-have', Category__c = 'Experience', Weight__c = 15, Min_Years__c = 4, Keywords__c = 'salesforce,apex,lwc,sales cloud,service cloud,experience cloud'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Integrations: REST APIs, Named Credentials, Platform Events or MuleSoft', Type__c = 'Nice-to-have', Category__c = 'Skill', Weight__c = 10, Keywords__c = 'rest,integration,mulesoft,platform events'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Service Cloud delivery experience', Type__c = 'Nice-to-have', Category__c = 'Experience', Weight__c = 10, Keywords__c = 'service cloud'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Degree in Computer Science or a related field', Type__c = 'Nice-to-have', Category__c = 'Education', Weight__c = 8),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Salesforce Platform Developer certification', Type__c = 'Nice-to-have', Category__c = 'Certification', Weight__c = 7, Keywords__c = 'platform developer'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Team leadership or mentoring', Type__c = 'Nice-to-have', Category__c = 'Experience', Weight__c = 8, Keywords__c = 'lead,mentor'),
    new Role_Requirement__c(Job_Role__c = role.Id, Requirement__c = 'Measurable delivery achievements', Type__c = 'Nice-to-have', Category__c = 'Achievement', Weight__c = 7)
};
System.debug('SEED created role ' + role.Id);
