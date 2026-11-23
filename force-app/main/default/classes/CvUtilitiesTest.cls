@IsTest
private class CvUtilitiesTest {
    @IsTest
    static void parsesCvDateFormats() {
        DateUtil.Parsed p = DateUtil.parse('2019-03', false);
        Assert.areEqual(Date.newInstance(2019, 3, 1), p.value);
        Assert.areEqual('Month', p.precision);
        Assert.areEqual(Date.newInstance(2019, 12, 1), DateUtil.parse('2019', true).value, 'Year-only end date uses December');
        Assert.areEqual('Year', DateUtil.parse('2019', false).precision);
        Assert.areEqual(3, DateUtil.parse('Mar 2019', false).value.month());
        Assert.areEqual(9, DateUtil.parse('September 2020', false).value.month());
        Assert.areEqual(7, DateUtil.parse('07/2018', false).value.month());
        Assert.areEqual('Day', DateUtil.parse('2020-02-15', false).precision);
        Assert.isTrue(DateUtil.parse('Present', true).isCurrent);
        Assert.isNull(DateUtil.parse('soon', false));
        Assert.isNull(DateUtil.parse('1890', false), 'Implausible years are rejected');
        Assert.isNull(DateUtil.parse(null, false));
    }

    @IsTest
    static void mergesOverlappingRanges() {
        List<List<Date>> ranges = new List<List<Date>>{
            new List<Date>{ Date.newInstance(2020, 1, 1), Date.newInstance(2020, 12, 1) },
            new List<Date>{ Date.newInstance(2020, 6, 1), Date.newInstance(2021, 5, 1) },
            new List<Date>{ Date.newInstance(2023, 1, 1), Date.newInstance(2023, 3, 1) }
        };
        Assert.areEqual(17 + 3, DateUtil.mergedMonths(ranges), 'Overlap counted once, gap not counted');
        Assert.areEqual(7, DateUtil.overlapMonths(ranges[0][0], ranges[0][1], ranges[1][0], ranges[1][1]));
        Assert.areEqual(0, DateUtil.overlapMonths(ranges[0][0], ranges[0][1], ranges[2][0], ranges[2][1]));
        Assert.areEqual('1 year 8 months', DateUtil.formatMonths(20));
        Assert.areEqual('0 months', DateUtil.formatMonths(0));
    }

    @IsTest
    static void normalisesTextForQuoteMatching() {
        Assert.areEqual('built apex - lwc "fast"', TextNormalizer.loose('Built  Apex – LWC “fast”'));
        Assert.areEqual('builtapexlwc', TextNormalizer.alnum('• Built Apex/LWC.'));
        List<String> kw = TextNormalizer.keywords('Does Sara have Apex and C# experience?');
        Assert.isTrue(kw.contains('apex'));
        Assert.isTrue(kw.contains('c#'));
        Assert.isFalse(kw.contains('experience'), 'Stop words removed');
    }

    @IsTest
    static void readsModelJson() {
        Map<String, Object> m = JsonUtil.parseObject('Here you go:\n```json\n{"a": "x", "n": "12 years", "l": ["p", ""]}\n```');
        Assert.areEqual('x', JsonUtil.str(m, 'a'));
        Assert.areEqual(12, JsonUtil.num(m, 'n'));
        Assert.areEqual(1, JsonUtil.strings(m, 'l').size());
        Assert.isNull(JsonUtil.str(m, 'missing'));
        try {
            JsonUtil.parseObject('no json here');
            Assert.fail('Expected INVALID_JSON');
        } catch (CvAgentException e) {
            Assert.areEqual(CvAgentException.INVALID_JSON, e.code);
            Assert.isFalse(e.isRetryable());
        }
        Assert.areEqual('abc…', JsonUtil.truncate('abcdef', 4));
    }

    @IsTest
    static void skillAliasesExpandBothWays() {
        String expanded = SkillAliases.expand('5 years of sfdc work');
        if (SkillAliases.all().containsKey('sfdc')) {
            Assert.isTrue(expanded.contains('salesforce'));
            Assert.isTrue(SkillAliases.expandKeywords(new List<String>{ 'salesforce' }).contains('sfdc'));
        }
        Assert.isNotNull(SkillAliases.asPromptText());
    }

    @IsTest
    static void settingsHaveDefaults() {
        CvAgentSettings.testOverride = new CV_Agent_Setting__mdt(LLM_Mode__c = 'Stub');
        Assert.isTrue(CvAgentSettings.isStubMode());
        Assert.areEqual(75, CvAgentSettings.strongThreshold());
        Assert.areEqual(55, CvAgentSettings.possibleThreshold());
        Assert.areEqual(3, CvAgentSettings.maxInlineAssessments());
        Assert.areEqual(10, CvAgentSettings.maxCandidatesPerQuery());
        Assert.areEqual(60, CvAgentSettings.maxEvidenceRows());
        Assert.areEqual(3, CvAgentSettings.maxAttempts());
        Assert.areEqual(35, CvAgentSettings.inlineBudgetSeconds());
        Assert.areEqual('CV_Answer_Question:v2', PromptCatalog.versionOf(PromptCatalog.ANSWER_QUESTION));
    }

    @IsTest
    static void liveServiceUnescapesAndWrapsFailures() {
        Assert.areEqual('a | "b" & c', PromptTemplateLlmService.unescape('a &#124; &quot;b&quot; &amp; c'));
        try {
            new PromptTemplateLlmService().generate(new LlmModels.Request('Does_Not_Exist').put('X', 'y'));
            Assert.fail('Expected an exception');
        } catch (CvAgentException e) {
            Assert.areEqual(CvAgentException.LLM_UNAVAILABLE, e.code, 'Model failures are retryable');
        }
    }
}
