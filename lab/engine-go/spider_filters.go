package main

import "encoding/json"

func spiderFilters(raw json.RawMessage) map[string][]Filter {
	var categories map[string]json.RawMessage
	if json.Unmarshal(raw, &categories) != nil {
		return nil
	}
	filters := make(map[string][]Filter)
	for id, value := range categories {
		var groups []spiderRecord
		if json.Unmarshal(value, &groups) != nil {
			var group spiderRecord
			if json.Unmarshal(value, &group) != nil {
				continue
			}
			groups = []spiderRecord{group}
		}
		for _, group := range groups {
			key := group.text("key")
			if key == "" {
				continue
			}
			filter := Filter{Key: key, Name: group.text("name"), Default: group.text("init")}
			if filter.Name == "" {
				filter.Name = key
			}
			var options []spiderRecord
			if json.Unmarshal(group["value"], &options) == nil {
				for _, option := range options {
					if option != nil {
						filter.Values = append(filter.Values, FilterValue{Name: option.text("n"), Value: option.text("v")})
					}
				}
			}
			filters[id] = append(filters[id], filter)
		}
	}
	return filters
}
